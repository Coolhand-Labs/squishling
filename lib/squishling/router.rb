# frozen_string_literal: true

module Squishling
  # Decides, per call, whether a squished method runs its Ruby implementation or the LLM.
  module Router
    # One squished call in progress. `phase` is :routing (deciding, e.g. running squish_when), :ruby (running
    # the implementation), or :llm (on the LLM path, including any fallback); `escalated` records that squish!
    # already sent it to the LLM.
    Frame = Struct.new(:receiver, :definition, :wrapper, :inputs, :phase, :escalated)

    FRAMES_KEY = :__squishling_frames__

    class << self
      def dispatch(receiver, name, args, kwargs, impl, wrapper:)
        if (frame = enclosing_frame(receiver, name, wrapper))
          return frame.definition.coerce(impl.call)
        end

        definition = receiver.class.squishling_definition(name)
        frame = Frame.new(receiver, definition, wrapper, definition.bind_arguments(args, kwargs), :routing, false)
        frames.push(frame)
        begin
          return route_to_llm(frame, definition, "predicate") if definition.squish?(receiver, frame.inputs)

          begin
            frame.phase = :ruby
            value = impl.call
          rescue NotImplementedError
            # After squish!, the error came from the LLM path (a fallback, a proc), not a missing implementation.
            raise if frame.escalated

            return route_to_llm(frame, definition, "not implemented")
          end

          definition.coerce(value)
        ensure
          frames.pop
        end
      end

      def current_frame(receiver)
        frames.reverse_each.find { |frame| frame.receiver.equal?(receiver) }
      end

      # squish!: hand the call in progress on this receiver to the LLM, with this call's overrides.
      def escalate(receiver, overrides)
        frame = current_frame(receiver)
        raise Error, "#{receiver.class}#squish! called outside a squished method" unless frame
        unless frame.phase == :ruby
          raise Error, "#{frame.definition.label}: squish! can only be called from the method's Ruby implementation, " \
                       "not from squish_when or while already on the LLM path (e.g. from squish_fallback)"
        end

        frame.escalated = true
        route_to_llm(frame, frame.definition.for_call(**overrides), "squish!")
      end

      private

      def route_to_llm(frame, definition, reason)
        log(definition, reason)
        previous = frame.phase
        frame.phase = :llm
        definition.invoke_llm(frame.receiver, frame.inputs)
      ensure
        frame.phase = previous
      end

      # Thread#[] is fiber-local, so concurrent fibers don't share frames.
      def frames
        Thread.current[FRAMES_KEY] ||= []
      end

      # The call in progress that this one is part of, which runs its Ruby implementation without routing again:
      # a subclass override's `super` (entered through an ancestor's wrapper), or a call made while deciding or on
      # the LLM path (squish_when, squish_fallback, an instructions proc). Only recursion from the Ruby
      # implementation itself is a new call, routed on its own.
      def enclosing_frame(receiver, name, wrapper)
        frame = frames.reverse_each.find do |candidate|
          candidate.receiver.equal?(receiver) && candidate.definition.name == name
        end
        frame unless frame.nil? || (frame.wrapper.equal?(wrapper) && frame.phase == :ruby)
      end

      def log(definition, reason)
        Squishling.config.logger&.debug("[Squishling] #{definition.label} -> LLM (#{reason})")
      end
    end
  end
end
