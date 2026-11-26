# frozen_string_literal: true

module Squishling
  # Decides, per call, whether a squished method runs its Ruby implementation or the LLM.
  module Router
    # One squished call in progress. `phase` is :routing (deciding, e.g. running squish_when), :ruby (running
    # the implementation), or :llm (on the LLM path, including any fallback); `handed_off` records that squish!
    # already sent it to the LLM.
    Frame = Struct.new(:receiver, :definition, :wrapper, :inputs, :phase, :handed_off, :rejected)

    FRAMES_KEY = :__squishling_frames__

    class << self
      def dispatch(receiver, name, args, kwargs, impl, wrapper:)
        if (frame = enclosing_frame(receiver, name, wrapper))
          return coerce_inner(frame, impl.call)
        end

        definition = receiver.class.squishling_definition(name)
        frame = Frame.new(receiver, definition, wrapper, definition.bind_arguments(args, kwargs), :routing, false, nil)
        frames.push(frame)
        begin
          return route_to_llm(frame, definition, "predicate") if definition.squish?(receiver, frame.inputs)

          run_ruby(frame, definition, impl)
        ensure
          frames.pop
        end
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

        hand_off_frame(frame, overrides, "squish!")
      end

      private

      # The Ruby implementation, held to the contract (see RubyPath); a failure that hands off goes to the LLM.
      def run_ruby(frame, definition, impl)
        frame.phase = :ruby
        ruby_path = RubyPath.new(frame, definition)
        ruby_path.call(impl) { |overrides, reason| hand_off_frame(frame, overrides, reason) }
      rescue NotImplementedError => e
        # After a hand-off, the error came from the LLM path (a fallback, a proc), not a missing implementation;
        # and one from the developer's own squish_validate is theirs to see.
        raise if frame.handed_off || ruby_path&.own?(e)

        route_to_llm(frame, definition, "not implemented")
      end

      def hand_off_frame(frame, overrides, reason)
        frame.handed_off = true
        route_to_llm(frame, frame.definition.for_call(**overrides), reason)
      end

      # An inner call (`super`, or the method called from squish_when or a fallback) hands its value to user code
      # that may reshape it, so only a Hash is typed (for accessor access); the outermost return is validated in full.
      # A Hash an inner call returns that the schema rejects is the outer call's rejected return when it gets out of
      # the Ruby implementation (e.g. a parent's, reached through super), so it is recorded for RubyPath.
      def coerce_inner(frame, value)
        value.is_a?(Hash) ? frame.definition.coerce(value) : value
      rescue InvalidOutputError => e
        frame.rejected ||= e
        raise
      end

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
