# frozen_string_literal: true

module Squishling
  # Holds the Ruby implementation of a squished call to the same contract as the LLM when both paths are validated
  # (see ClassMethods#squish_validate): its return is typed and checked by squish_validate, and a rejected return is
  # handed to the LLM with the draft and what was wrong with it. Errors the Ruby raises are squish_rescue's.
  class RubyPath
    # Added to the purpose of a hand-off of a rejected Ruby return, after the declared sections.
    HANDOFF_NOTE = <<~NOTE.strip
      The Ruby implementation of this operation ran first on these arguments, and its result was not accepted. The
      context holds what went wrong: "ruby_draft" is the output it produced, and "ruby_problems" is what was wrong with
      it. Treat the draft as a hint, not as the answer. Respond with a corrected result.
    NOTE

    SOURCE_NOTE = "Its source, or the code around it, is included in this prompt."
    SOURCE_TYPES = [Module, Method, UnboundMethod].freeze

    def initialize(frame, definition)
      @frame = frame
      @definition = definition
    end

    # The typed result of the Ruby path's return value. Under both_paths a return the schema or squish_validate
    # rejects is handed to the LLM: the block is yielded the squish! overrides and the reason for the log, and what it
    # returns is the result. Otherwise a rejected return raises. Exceptions from the developer's own squish_validate
    # propagate as they are.
    def accept(value, &)
      typed, rejection = coerce(value)
      return reject(rejection, &) if rejection

      both_paths? ? check(typed, &) : typed
    end

    # A rejected Ruby return: handed off under both_paths, raised otherwise. The handoff happens in the rescue, so the
    # rejection is the cause of whatever the LLM path raises. Also called for a parent's rejected return, raised
    # through super.
    def reject(error, &)
      raise error
    rescue InvalidOutputError
      raise unless handoff?

      hand_off(error, &)
    end

    private

    # The typed return, or the rejection the schema raised for it.
    def coerce(value)
      [@definition.coerce(value), nil]
    rescue InvalidOutputError => e
      [nil, e]
    end

    # squish_validate on the typed result.
    def check(typed, &)
      problems = OutputCheck.new(@definition, @frame.receiver, @frame.inputs).validator_errors(typed)
      return typed if problems.empty?

      details = InvalidOutputError::Detail.from(problems, :validator)
      reject(InvalidOutputError.new(errors: details, raw: typed, source: "Deterministic"), &)
    end

    def handoff?
      both_paths? && !@frame.handed_off && llm_capable?
    end

    # Whether both paths are validated: the class's `squish_validate both_paths:`, else the configured default.
    def both_paths?
      [@definition.klass.squishling_both_paths, Squishling.config.validate_both_paths].find { |on| !on.nil? }
    end

    # A hand-off needs something to say and a shape to answer in; a class without them only types Ruby's return.
    def llm_capable?
      !@definition.purpose(@frame.receiver).to_s.empty? && !@definition.schema.nil?
    end

    def hand_off(error)
      reason = "ruby output rejected"
      Squishling.config.logger&.warn("[Squishling] #{@definition.label} #{reason}, handing off to the LLM")
      yield({ context: context(error), append_to_purpose: [note] }, reason)
    end

    # What the Ruby path produced and why it was refused.
    def context(error)
      { ruby_draft: draft(error.raw), ruby_problems: problems(error) }.compact
    end

    def problems(error)
      checker = OutputCheck.new(@definition, @frame.receiver, @frame.inputs)
      checker.cap(error.error_details).map(&:message)
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

    def note
      # Procs aren't evaluated here, so source they render is not claimed.
      shown = Appendices.resolve(@definition.append_to_purpose)
      source = shown.any? { |item| SOURCE_TYPES.any? { |type| item.is_a?(type) } }
      source ? "#{HANDOFF_NOTE} #{SOURCE_NOTE}" : HANDOFF_NOTE
    end
  end
end
