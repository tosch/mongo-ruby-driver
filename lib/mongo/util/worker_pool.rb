module Mongo
  module Async

    class WorkerPool
      attr_reader :workers

      def initialize size
        @jobs = Queue.new
        @workers = Queue.new

        @size = size
        spawn_pool @size
      end

      def enqueue command, args, callback
        # call compact to remove any nil arguments
        @jobs << [command, args.compact, callback]
      end

      private

      def spawn_pool size
        size.times do
          thread = Thread.new do
            while true do
              do_work
            end
          end

          thread.abort_on_exception = true
          @workers << thread
        end
      end

      def do_work
        # blocks on #pop until a job is available
        command, cmd_args, callback = @jobs.pop
        exception, result = nil, nil

        # Call the original command with its arguments; capture
        # and save any result and/or exception
        begin
          result = command.call *cmd_args
        rescue => e
          exception = e
        end

        # Execute the callback and pass in the exception and result;
        # in successful cases, the exception should be nil
        callback.call exception, result
      end
    end # Workers

  end # Async
end # Mongo
