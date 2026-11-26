# frozen_string_literal: true

module Squishling
  # Holds the Ruby implementation of a squished call to the same contract as the LLM when both paths are validated
  # (see ClassMethods#squish_validate): its return is typed and checked by squish_validate, and a rejected return is
  # handed to the LLM with the draft and what was wrong with it. So is an error the class names with squish_rescue.
  class RubyPath
    # Added to the purpose of every automatic hand-off, ahead of the sections the developer declared for them.
    HANDOFF_NOTE = <<~NOTE.strip
      The Ruby implementation of this operation ran first on these arguments, and its result was not accepted. The
      context holds what went wrong: "ruby_draft" is the output it produced, "ruby_problems" is what was wrong with
      it, and "ruby_error" is the error it raised. Treat the draft as a hint, not as the answer. Respond with a
      corrected result.
    NOTE

    SOURCE_NOTE = "Its source, or the code around it, is included in this prompt."
    SOURCE_TYPES = [Module, Method, UnboundMethod].freeze

    class << self
      # The exception classes a squish_rescue names: StandardError classes, which are all a rescue clause can catch.
      def normalize_rescue(classes, label)
        unless classes.all? { |klass| klass.is_a?(Class) && klass <= StandardError }
          raise ConfigurationError, "#{label} must name StandardError classes, got #{classes.inspect}"
        end

        classes.freeze
      end
    end

    def initialize(frame, definition)
      @frame = frame
      @definition = definition
      @own = nil
      @rejected = nil
    end

    # Whether the error came from the developer's own squish_validate, which always propagates.
    def own?(error)
      error.equal?(@own)
    end

    # Runs the implementation and returns its typed, checked result. When the Ruby path fails in a way that
    # hands off, yields the squish! overrides and the reason for the log, and returns what the block returns.
    def call(impl, &)
      value = impl.call
      return @definition.coerce(value) if @frame.handed_off # squish! already returned a checked LLM result

      check(rejecting { @definition.coerce(value) })
    rescue StandardError => e
      raise unless handoff?(e)

      hand_off(e, &)
    end

    private

    # squish_validate on the typed result, when both paths are validated. Its own exceptions (even a
    # NotImplementedError) are the developer's, so they are marked and propagate instead of being handed off.
    def check(typed)
      return typed unless @definition.both_paths?

      problems = begin
        OutputCheck.new(@definition, @frame.receiver, @frame.inputs).validator_errors(typed)
      rescue Exception => e # rubocop:disable Lint/RescueException -- marked, then re-raised untouched
        @own = e
        raise
      end
      return typed if problems.empty?

      rejecting { raise InvalidOutputError.new(errors: OutputCheck.cap(problems), raw: typed, source: "Deterministic") }
    end

    # Records the InvalidOutputError that is this call's own rejected return, so it isn't mistaken for one raised
    # by another squished object that the Ruby called.
    def rejecting
      yield
    rescue InvalidOutputError => e
      @rejected = e
      raise
    end

    def handoff?(error)
      return false if @frame.handed_off || own?(error) || error.is_a?(ConfigurationError)
      return false unless @definition.llm_capable?

      # The Ruby path's own rejected return follows both_paths, whatever squish_rescue names.
      return @definition.both_paths? if contract_failure?(error)

      @definition.rescue_classes.any? { |klass| error.is_a?(klass) }
    end

    # The Ruby path's own return was rejected. An InvalidOutputError raised inside the Ruby (by another squished
    # object, or by `result(...)`) is an ordinary error: its draft and raw output stay out of this hand-off.
    def contract_failure?(error)
      error.equal?(@rejected) || error.equal?(@frame.rejected)
    end

    # Called from the rescue clause, so Ruby links the Ruby failure as the cause of whatever the LLM path raises.
    def hand_off(error)
      reason = contract_failure?(error) ? "ruby output rejected" : "ruby raised #{error.class}"
      Squishling.config.logger&.warn("[Squishling] #{@definition.label} #{reason}, handing off to the LLM")
      yield overrides(error), reason
    end

    def overrides(error)
      extras = @definition.rescue_overrides
      sections = extras.fetch(:append_to_purpose, [])
      { **extras, context: context(error), append_to_purpose: [note(sections), *sections] }
    end

    # What the Ruby path produced and why it was refused. An exception is described by class and message (never its
    # backtrace) when the context is built.
    def context(error)
      return { ruby_error: described(error) } unless contract_failure?(error)

      { ruby_draft: draft(error.raw), ruby_problems: OutputCheck.cap(error.errors) }.compact
    end

    # Class and message, the message cut like the draft: an HTTP client's error can carry a whole response body.
    def described(error)
      { class: Invoker.exception_class_name(error.class), message: error.message.to_s[0, Invoker::MAX_FORWARDED_CHARS] }
    end

    # The draft as JSON data, or its first characters when it is large. Only plain data is sent: an arbitrary
    # object would be serialized by its own to_json, which the developer never named. nil otherwise, and when the
    # draft can't be represented.
    def draft(raw)
      return unless [Hash, Array, Result::Instance].any? { |type| raw.is_a?(type) }

      json = JSON.generate(Result.deep_to_h(raw))
      limit = Invoker::MAX_FORWARDED_CHARS
      json.size > limit ? "#{json[0, limit]}..." : JSON.parse(json)
    rescue StandardError # best-effort context: a draft that can't be serialized is left out, not raised from here
      nil
    end

    def note(sections)
      # Procs aren't evaluated here, so source they render is not claimed.
      shown = Appendices.resolve(@definition.append_to_purpose + sections)
      source = shown.any? { |item| SOURCE_TYPES.any? { |type| item.is_a?(type) } }
      source ? "#{HANDOFF_NOTE} #{SOURCE_NOTE}" : HANDOFF_NOTE
    end
  end
end
