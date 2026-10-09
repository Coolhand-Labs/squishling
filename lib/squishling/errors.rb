# frozen_string_literal: true

module Squishling
  class Error < StandardError; end

  # A programming or setup mistake (missing purpose/schema, non-strict schema, unknown model,
  # missing API key). Never retried and never passed to squish_fallback.
  class ConfigurationError < Error; end

  # Output that didn't match the schema (or a squish_validate check): from the LLM after every attempt in the
  # escalation, or from the deterministic path.
  class InvalidOutputError < Error
    # models: the model ids tried, one per attempt (nil entries mean RubyLLM's default model).
    attr_reader :errors, :raw, :attempts, :models

    def initialize(errors:, raw: nil, source: "LLM", attempts: nil, models: nil)
      @errors = errors
      @raw = raw
      @attempts = attempts
      @models = models
      tries = attempts ? " after #{attempts} attempt#{'s' unless attempts == 1}" : ""
      super("#{source} output was invalid#{tries}: #{errors.join('; ')}")
    end
  end

  # The squishsum harnesses' samples were valid but didn't agree, and either no judge was declared
  # (verdict nil) or the judge rejected both (verdict :neither, with its reason). candidates holds the two
  # typed results, so a squish_fallback can still return one of them, and raw both as Hashes. models names the
  # model behind each role (sample a, sample b, then the judge if one ran), not one entry per attempt; attempts
  # is nil.
  class DisagreementError < InvalidOutputError
    attr_reader :candidates, :verdict, :reason

    def initialize(candidates:, verdict: nil, reason: nil, models: nil)
      @candidates = candidates
      @verdict = verdict
      @reason = reason
      error = verdict ? "the judge rejected both samples" : "the two samples disagreed"
      error += " (#{reason})" if reason && !reason.strip.empty?
      super(errors: [error], raw: candidates.map(&:to_h), models:)
    end
  end

  # The LLM call itself failed (rate limit, server error, timeout, connection) after RubyLLM's own
  # HTTP retries. The original exception is available as #cause.
  class LLMError < Error; end
end
