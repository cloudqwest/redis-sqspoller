require "logger"
require "aws-sdk"
require 'base64'
require 'openssl'

module Sqspoller
  class QueueController

    # expecting the queue name to be <environment>_outbound_messages_<company_id>
    REGEXP = /(?<environment>\w+)-outbound-messages-(?<window_identifier>[\w-]+)/

    attr_accessor :threads,
                  :queue_name

    def initialize args
      @logger = args[:logger]
      self.queue_name = args[:queue_name]
      @polling_threads_count = args[:polling_threads_count]
      @sqs = Aws::SQS::Client.new access_key_id: args[:access_key_id],
                                  secret_access_key: args[:secret_access_key],
                                  region: args[:region]
      @queue_details = @sqs.get_queue_url(queue_name: queue_name)
      self.threads = []
      @task_delegator = args[:task_delegator]
      match_data = REGEXP.match queue_name
      @maintenance_window = if match_data
                              @cache_key = "#{match_data[:environment]}::OutboundMessages::MaintenanceWindowOpen::#{match_data[:window_identifier]}"
                              @window_identifier = match_data[:window_identifier]
                              true
                            else
                              false
                            end
    end

    def start
      queue_url = @queue_details.queue_url
      @logger.info "Going to start polling threads for queue: #{queue_url}"
      @polling_threads_count.times do
        self.threads << start_thread(queue_url)
      end
    end

    def start_thread(queue_url)
      Thread.new do
        poller = Aws::SQS::QueuePoller.new(queue_url)
        poller.before_request do |stats|
           @logger.info "  Blocking the poller on maintenance window, queue_url : #{queue_url}"
          block_on_maintenance_window
        end

        loop do
          @logger.info "  Polling queue #{queue_name} for messages"
          poller.poll do |received_message|
            begin
              @logger.info "   Received message from #{@queue_name} : #{received_message.message_id}"
              @task_delegator.process self, received_message, queue_name
            rescue Exception => e
              @logger.info "   Encountered error #{e.message} while submitting message to worker from queue #{queue_name}"
              throw :skip_delete
            end
          end
           @logger.info "  looping over Poller.poll, processed received_message: #{received_message}"
        end
        @logger.info "  Stopping thread execution, queue_url : #{queue_url}"
      end
    rescue ThreadError => e
       @logger.info "  Encountered Thread error #{e.message} while starting thread for queue_url #{queue_url}"
    rescue => e
       @logger.info "  Encountered error #{e.message} while starting thread for queue_url #{queue_url}"
    end

    def delete_message(receipt_handle)
      @sqs.delete_message queue_url: @queue_details.queue_url,
                          receipt_handle: receipt_handle
    end

    def block_on_maintenance_window
      @logger.info "  checking for maintenance_window, #{@maintenance_window}"
      if @maintenance_window
        loop do
          window_open = REDIS.get @cache_key
          @logger.info "  checking for window_open, #{window_open}"
          if window_open
            @logger.info "   Maintenance Window is open for #{@window_identifier}, sleeping for 5 minutes"
            sleep 300
          else
            break
          end
        end
      end
    end
  end
end
