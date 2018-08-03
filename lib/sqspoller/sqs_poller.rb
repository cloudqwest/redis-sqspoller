require "logger"
require "concurrent"
require "net/http"
require "yaml"
require "erb"
require 'redis'
require "sqspoller/worker_task"
require "sqspoller/sns_forwarder"
require "sqspoller/message_delegator"
require "sqspoller/queue_controller"

module Sqspoller
  REDIS = Redis.new host: ENV['REDIS_HOST'], port: ENV['REDIS_PORT']
  HEADERS = { 'Content-Type' => 'application/json',
              'Accept' => 'application/json'
            }

  class SqsPoller
    class << self

      def symbolize(map)
        if map.class == Hash
          map.inject({}) do |memo,(k,v)|
            memo[k.to_sym] = symbolize(v)
            memo
          end
        else
          map
        end
      end

      def daemonize(filename)
        raise 'Must run as root' if Process.euid != 0

        raise 'First fork failed' if (pid = fork) == -1
        exit unless pid.nil?

        Process.setsid
        raise 'Second fork failed' if (pid = fork) == -1
        exit unless pid.nil?
        puts "Daemon pid: #{Process.pid}" # Or save it somewhere, etc.

        Dir.chdir '/'
        File.umask 0000

        STDIN.reopen filename
        STDOUT.reopen '/dev/null', 'a'
        STDERR.reopen STDOUT
      end

      def start_poller content_name, queue_config_name, access_key_id, secret_access_key, region, log_filename=nil, redis_or_file=false
        puts "StartPoller"

        poller_args = {content_name:      content_name,
                       queue_config_name: queue_config_name.to_sym,
                       access_key_id:     access_key_id,
                       secret_access_key: secret_access_key,
                       region:            region,
                       log_filename:      log_filename,
                       redis_or_file:     redis_or_file
                      }

        if redis_or_file
          if REDIS.get('random_key') == nil
            puts "Able to connect to Redis"
          else
            puts "*** Unable to connect to Redis"
            exit -1
          end
        end
        if log_filename.nil? || log_filename.empty?
          poller_args[:log_filename] = STDOUT
          puts "Did not receive log file name"
          fork do
            Process.daemon nil, :noclose
            start_queues_with_config poller_args
          end
        else
          puts "Did receive log file name"
          daemonize log_filename
          start_queues_with_config poller_args
        end
      end

      def load_config_from_file filename
        content = IO.read filename
        symbolize_from_content content
      end

      def load_config_from_redis redis_key
        content = REDIS.get redis_key
        symbolize_from_content content
      end

      def symbolize_from_content content
        erb = ERB.new content
        yaml = YAML.load erb.result
        symbolize yaml
      end

      def start_queues_with_config poller_args
        @logger = Logger.new(poller_args[:log_filename])
        poller_args[:logger] = @logger
        @logger.info "Starting version: #{VERSION}"
        @logger.info "Get config"
        config = if poller_args[:redis_or_file]
                   load_config_from_redis poller_args[:content_name]
                 else
                   load_config_from_file poller_args[:content_name]
                 end
        @logger.info "Config: #{config.inspect}"
        queues_config = config[poller_args[:queue_config_name]]
        if queues_config
          @logger.info "QueuesConfig: #{queues_config.inspect}"
        else
          @logger.error "Unable to fetch Queue Config"
        end

        @logger.info "Started poller method"

        message_delegator = worker_pool_init config[:worker_configuration].merge(poller_args), queues_config, poller_args[:log_filename]

        if poller_args[:redis_or_file]
          start_all_queues_with_refresh queues_config, message_delegator, poller_args, config[:worker_configuration][:refresh_interval_in_seconds] || 3600
        else
          start_all_queues  queues_config, message_delegator, poller_args
        end
      end

      def start_all_queues_with_refresh queues_config, message_delegator, poller_args, refresh_interval
        @logger.info "Start all queues with refresh"
        queues = {}
        loop do
          queue_names = queues_config.keys
          queues_config.keys.each do |queue|
            @logger.info "    Checking queue #{queue}"
            if queues[queue]
              if queues[queue].all_threads_alive?
                @logger.info "      Queue: #{queue} not created, already initialized and running"
              else
                @logger.info "      Queue: #{queue} previously created, however not all threads are running. Restarting."
                queues[queue] = start_queue_controller queues_config, queue, message_delegator, poller_args
              end
            else
              queues[queue] = start_queue_controller queues_config, queue, message_delegator, poller_args
            end
          end
          @logger.info "  Done creating queues, sleeping for #{refresh_interval} seconds"
          sleep refresh_interval
          @logger.info "  Refreshing config"
          config = load_config_from_redis poller_args[:content_name]
          queues_config = config[poller_args[:queue_config_name]]
          refresh_interval = config[:worker_configuration][:refresh_interval_in_seconds]
        end
      end

      def start_all_queues queues_config, message_delegator, poller_args
        @logger.info "Start all queues " 
        queues_config.keys.each do |queue|
          start_queue_controller queues_config, queue, message_delegator, poller_args
        end
      end

      def worker_pool_init worker_config, queues_config, logger_file
        total_poller_threads = queues_config.keys.reduce(0) do |sum, queue|
                                 sum += queues_config[queue][:polling_threads]
                               end
        initialize_worker worker_config, total_poller_threads, logger_file
      end

      def start_queue_controller queues_config, queue, message_delegator, poller_args
        if queues_config[queue][:polling_threads] == 0
          @logger.info "  Polling disabled for queue: #{queue}"
          nil
        else
          @logger.info "  Creating QueueController object for queue: #{queue}"
          qc = QueueController.new queue_name: queue,
                                   polling_threads_count: queues_config[queue][:polling_threads],
                                   task_delegator: message_delegator,
                                   access_key_id: poller_args[:access_key_id],
                                   secret_access_key: poller_args[:secret_access_key],
                                   region: poller_args[:region],
                                   logger_file: poller_args[:log_filename],
                                   logger: poller_args[:logger]
          qc.start
          qc
        end
      end

      def initialize_worker worker_configuration, total_poller_threads, logger_file
        worker_thread_count = worker_configuration[:concurrency] || total_poller_threads
        waiting_tasks_ratio = worker_configuration[:waiting_tasks_ratio] || 1

        klass = worker_configuration[:worker_class].split('::').reduce(Object, :const_get)
        worker_task = klass.new worker_configuration

        MessageDelegator.new worker_thread_count, waiting_tasks_ratio, worker_task, logger_file
      end
    end
  end
end
