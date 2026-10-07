# frozen_string_literal: true

module Squishling
  # Decides, per call, whether a squished method runs its Ruby implementation or the LLM.
  module Router
    Frame = Struct.new(:receiver, :definition)

    FRAMES_KEY = :__squishling_frames__

    class << self
      def dispatch(receiver, name, args, kwargs, impl)
        # A subclass override calling `super` reaches the parent's wrapper; it's already routed.
        if (frame = active_frame(receiver, name))
          return frame.definition.coerce(impl.call)
        end

        definition = receiver.class.squishling_definition(name)
        frames.push(Frame.new(receiver, definition))
        begin
          inputs = definition.bind_arguments(args, kwargs)

          if definition.squish?(receiver, inputs)
            log(definition, "predicate")
            return definition.invoke_llm(receiver, inputs)
          end

          begin
            value = impl.call
          rescue NotImplementedError
            log(definition, "not implemented")
            return definition.invoke_llm(receiver, inputs)
          end

          definition.coerce(value)
        ensure
          frames.pop
        end
      end

      def current_frame(receiver)
        frames.reverse_each.find { |frame| frame.receiver.equal?(receiver) }
      end

      private

      # Thread#[] is fiber-local, so concurrent fibers don't share frames.
      def frames
        Thread.current[FRAMES_KEY] ||= []
      end

      def active_frame(receiver, name)
        frames.find { |frame| frame.receiver.equal?(receiver) && frame.definition.name == name }
      end

      def log(definition, reason)
        Squishling.config.logger&.debug("[Squishling] #{definition.label} -> LLM (#{reason})")
      end
    end
  end
end
