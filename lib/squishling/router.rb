# frozen_string_literal: true

module Squishling
  # Decides, per call, whether a squished method runs its Ruby implementation or the LLM.
  module Router
    # One squished call in progress. `phase` is :routing (deciding, e.g. running squish_when), :ruby (running
    # the implementation), or :llm (on the LLM path, including any fallback); `handed_off` records that squish!
    # already sent it to the LLM. call_id is the id the caller gave this call (see CallId), or nil.
    Frame = Struct.new(:receiver, :definition, :wrapper, :inputs, :phase, :handed_off, :call_id)

    FRAMES_KEY = :__squishling_frames__

    class << self
      def dispatch(receiver, name, args, kwargs, impl, wrapper:)
        if (frame = enclosing_frame(receiver, name, wrapper))
          return coerce_inner(frame, impl.call)
        end

        definition = receiver.class.squishling_definition(name)
        frame = Frame.new(receiver, definition, wrapper, definition.bind_arguments(args, kwargs), :routing, false,
          CallId.claim)
        frames.push(frame)
        begin
          return route_to_llm(frame, definition, "predicate") if definition.squish?(receiver, frame.inputs)

          begin
            frame.phase = :ruby
            started = Apprentice.clock
            value = impl.call
          rescue NotImplementedError => e
            # After squish!, the error came from the LLM path (a fallback, a proc), not a missing implementation.
            # Otherwise it propagates unless it is the method's own stub (see Wrapper.stub?).
            raise if frame.handed_off || !Wrapper.stub?(e)

            return route_to_llm(frame, definition, "not implemented")
          end

          ruby_seconds = Apprentice.clock - started
          definition.coerce(value).tap do |result|
            # The Ruby path answered (not squish!), so an apprentice may run the LLM alongside it: once, for the
            # outermost call, not again for each call the method makes to itself.
            shadow(frame, definition, result, ruby_seconds)
          end
        ensure
          frames.pop
        end
      end

      # Runs the block as the LLM path of a call on this thread (an apprentice's shadow run, which may run on another
      # thread than the call): calls back into the method run its Ruby, and squish! is refused, as on the LLM path.
      def within(receiver, definition, inputs)
        frames.push(Frame.new(receiver, definition, nil, inputs, :llm, false))
        yield
      ensure
        frames.pop
      end

      def current_frame(receiver)
        frames.reverse_each.find { |frame| frame.receiver.equal?(receiver) }
      end

      # squish!: hand the call in progress on this receiver to the LLM, with this call's overrides.
      def hand_off(receiver, overrides)
        frame = current_frame(receiver)
        raise Error, "#{receiver.class}#squish! called outside a squished method" unless frame
        unless frame.phase == :ruby
          raise Error, "#{frame.definition.label}: squish! can only be called from the method's Ruby implementation, " \
                       "not from squish_when or while already on the LLM path (e.g. from squish_fallback)"
        end

        frame.handed_off = true
        route_to_llm(frame, frame.definition.for_call(**overrides), "squish!")
      end

      private

      # An inner call (`super`, or the method called from squish_when or a fallback) hands its value to user code
      # that may reshape it, so only a Hash is typed (for accessor access); the outermost return is validated in full.
      def coerce_inner(frame, value)
        value.is_a?(Hash) ? frame.definition.coerce(value) : value
      end

      def route_to_llm(frame, definition, reason)
        log(definition, reason)
        previous = frame.phase
        frame.phase = :llm
        definition.invoke_llm(frame.receiver, frame.inputs, call_id: frame.call_id)
      ensure
        frame.phase = previous
      end

      # Hands a call the Ruby path answered to its apprentice (see Apprentice), unless squish! answered it, or it is
      # nested in another call of the same method.
      def shadow(frame, definition, result, ruby_seconds)
        return if frame.handed_off || nested?(frame)

        Apprentice.shadow(frame, definition, result, ruby_seconds)
      end

      # Whether the call runs inside another call of the same method (recursion, on this instance or another).
      def nested?(frame)
        frames.any? do |outer|
          !outer.equal?(frame) && outer.definition.label == frame.definition.label
        end
      end

      # Thread#[] is fiber-local, so concurrent fibers don't share frames.
      def frames
        Thread.current[FRAMES_KEY] ||= []
      end

      # The call in progress that this one is part of, which runs its Ruby implementation without routing again:
      # a subclass override's `super` (entered through an ancestor's wrapper), or a call made while deciding or on
      # the LLM path (squish_when, squish_fallback, a purpose proc). Only recursion from the Ruby
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
