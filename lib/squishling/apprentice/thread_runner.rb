# frozen_string_literal: true

module Squishling
  module Apprentice
    # The built-in background runner (config.apprentice_runner = :thread): a small pool of threads that run shadow
    # runs after the caller has its Ruby result, so the LLM adds no latency to the call. At most max_queue runs are
    # pending (queued or running) at once; a run beyond that is dropped and logged, never waited for. Threads start on
    # first use and again in a forked child (a preforking server's workers), and pending runs get a few seconds to
    # finish when the process exits.
    #
    # In Rails, each run is wrapped in the Rails executor, as a background job would be: the caller isn't waiting on
    # it (unlike a squishsum's sample threads, which must not enter the executor the caller holds), and the run may
    # touch the app's code and connections (purpose procs, squish_validate, the report hook).
    #
    #   config.apprentice_runner = Squishling::Apprentice::ThreadRunner.new(size: 4, max_queue: 500)
    class ThreadRunner
      # How long pending runs get to finish when the process exits.
      EXIT_TIMEOUT = 5

      attr_reader :size, :max_queue

      def initialize(size: 2, max_queue: 100)
        @size = positive!(size, :size)
        @max_queue = positive!(max_queue, :max_queue)
        @lock = Mutex.new
        @finished = ConditionVariable.new
        @pid = nil
        @exit_hook = false
      end

      # Queues the job, or drops it (logged) when max_queue runs are already pending. Returns whether it was queued.
      def call(job)
        queued = @lock.synchronize do
          reset_after_fork
          next false if @pending >= @max_queue

          start_workers # first, so a thread that can't start doesn't leave a run counted
          @pending += 1
          @queue << job
          true
        end
        warn_dropped unless queued
        queued
      end

      # Waits until no run is pending, for up to timeout seconds (nil: as long as it takes). Returns whether none is.
      def drain(timeout: nil)
        deadline = timeout && (Apprentice.clock + timeout)
        @lock.synchronize { @pid != Process.pid || wait_until_finished(deadline) }
      end

      # The runs queued or running.
      def pending
        @lock.synchronize { @pid == Process.pid ? @pending : 0 }
      end

      private

      # Whether no run is pending by the deadline (nil: none). Called with the lock held.
      def wait_until_finished(deadline)
        until @pending.zero?
          remaining = deadline && (deadline - Apprentice.clock)
          return false if remaining && remaining <= 0

          @finished.wait(@lock, remaining)
        end
        true
      end

      def positive!(value, name)
        return value if value.is_a?(Integer) && value.positive?

        raise ConfigurationError, "Apprentice::ThreadRunner #{name}: must be a positive Integer, got #{value.inspect}"
      end

      # A forked child inherits the queue and the count but not the threads: it starts afresh. Called with the lock.
      def reset_after_fork
        return if @pid == Process.pid

        @pid = Process.pid
        @queue = Queue.new
        @workers = []
        @pending = 0
        register_exit_hook
      end

      # Called with the lock held.
      def start_workers
        @workers.select!(&:alive?)
        (@size - @workers.size).times do
          worker = Thread.new { work }
          worker.name = "squishling-apprentice"
          worker.report_on_exception = false
          @workers << worker
        end
      end

      def work
        queue = @lock.synchronize { @queue }
        while (job = queue.pop)
          begin
            perform(job)
          ensure
            finished
          end
        end
      end

      def finished
        @lock.synchronize do
          @pending -= 1
          @finished.broadcast if @pending.zero?
        end
      end

      def perform(job)
        executor = rails_executor
        executor ? executor.wrap { job.call } : job.call
      rescue StandardError, ScriptError => e # a job's own failure must not stop the worker
        Squishling.config.logger&.error("[Squishling] apprentice run failed: #{Apprentice.describe(e)}")
      end

      def rails_executor
        return unless defined?(::Rails) && ::Rails.respond_to?(:application)

        application = ::Rails.application
        application.executor if application.respond_to?(:executor)
      end

      def register_exit_hook
        return if @exit_hook

        @exit_hook = true
        at_exit { drain(timeout: EXIT_TIMEOUT) }
      end

      def warn_dropped
        Squishling.config.logger&.warn("[Squishling] apprentice run dropped: #{@max_queue} runs already pending")
      end
    end
  end
end
