# frozen_string_literal: true

module Squishling
  module Apprentice
    # One shadow run: the LLM path of a call whose Ruby result the caller already has. Starts on the caller's thread
    # (when:, then the request is built, so the instance's state is read before the caller moves on), and the rest
    # (the requests, validation, compare:, the report) runs as a job on the configured runner.
    class Shadow
      # What a shadow run absorbs and reports: errors, and a NotImplementedError (a ScriptError) from the developer's
      # callbacks. Not the rest of Exception (an Interrupt, a SignalException, an exit), which still ends the process.
      ABSORBED = [StandardError, NotImplementedError].freeze
      def initialize(frame, definition, settings, ruby, ruby_seconds)
        @frame = frame
        @definition = definition
        @settings = settings
        @ruby = ruby
        @ruby_seconds = ruby_seconds
        @receiver = frame.receiver
        @inputs = frame.inputs
        @runner = Apprentice.runner
      end

      # Like the LLM path, this runs with the call's frame on :llm: the method called again from a purpose proc runs
      # its Ruby, and squish! is refused.
      def start
        previous = @frame.phase
        @frame.phase = :llm
        begin
          return unless chosen?

          invoker = Invoker.new(@definition, @receiver, @inputs, call_id: @frame.call_id)
          built = invoker.prepare
        rescue *ABSORBED => e
          raise if Apprentice.unabsorbable?(e)

          return dispatch { deliver(llm: nil, match: nil, error: e, invoker: nil, llm_seconds: nil) }
        ensure
          @frame.phase = previous
        end
        dispatch { perform(invoker, built) }
      end

      private

      def chosen?
        condition = @settings[:when]
        condition.nil? || @receiver.instance_exec(**@inputs, &condition)
      end

      # Hands the work to the runner. On the inline runner it is part of the call, so the report hook's own exception
      # reaches the caller. On any other, there is no caller left to raise to: it is logged. A runner that refuses the
      # job (a full pool) drops it, logged, rather than fail the call.
      def dispatch(&work)
        @runner.equal?(INLINE) ? yield : submit(background(work))
      end

      def submit(job)
        @runner.call(job)
      rescue *ABSORBED => e
        Squishling.config.logger&.warn("[Squishling] #{@definition.label} apprentice run dropped: the runner " \
                                       "raised #{e.class}")
      end

      def background(work)
        lambda do
          work.call
        rescue *ABSORBED => e
          next Apprentice.hold(e) if Apprentice.unabsorbable?(e) # raised by the next Apprentice.drain

          Squishling.config.logger&.error("[Squishling] #{@definition.label} apprentice report failed: " \
                                          "#{Apprentice.describe(e)}")
        end
      end

      def perform(invoker, built)
        started = Apprentice.clock
        llm, match, error = run(invoker, built)
        deliver(llm:, match:, error:, invoker:, llm_seconds: Apprentice.clock - started)
      end

      # [the LLM's result, whether it matched, nil], or [what it got to, nil, the error that ended it].
      def run(invoker, built)
        llm = nil
        Router.within(@receiver, @definition, @inputs) do
          llm = invoker.call(built)
          [llm, compare(llm), nil]
        end
      rescue *ABSORBED => e
        raise if Apprentice.unabsorbable?(e)

        [llm, nil, e]
      end

      def compare(llm)
        compare = @settings[:compare]
        return Schema.same?(@ruby, llm) unless compare

        @receiver.instance_exec(@ruby, llm, **@inputs, &compare) ? true : false
      end

      def deliver(llm:, match:, error:, invoker:, llm_seconds:)
        origin = llm.nil? ? nil : invoker&.origin(llm)
        call_id = invoker&.call_id || @frame.call_id
        log(match, error)
        metadata = { label: @definition.label, call_id:, request_id: origin&.request_id, model: origin&.model,
                     ruby_seconds: @ruby_seconds, llm_seconds: }
        hook = @settings.fetch(:report) { Squishling.config.apprentice_report }
        KeywordHook.call(hook, ruby: @ruby, llm:, match:, error:, inputs: @inputs, metadata:) if hook
        review(Review.new(label: @definition.label, call_id:, request_id: origin&.request_id, model: origin&.model,
          ruby: Schema.plain(@ruby), match:, error: error&.class))
      end

      # The observer hears the review when it takes them (see Observer.review).
      def review(review)
        Observer.review(review)
      end

      def log(match, error)
        logger = Squishling.config.logger
        return unless logger

        if error
          logger.warn("[Squishling] #{@definition.label} apprentice LLM run failed: #{Apprentice.describe(error)}")
        else
          logger.debug("[Squishling] #{@definition.label} apprentice: the LLM #{match ? 'matched' : 'differed'}")
        end
      end
    end
  end
end
