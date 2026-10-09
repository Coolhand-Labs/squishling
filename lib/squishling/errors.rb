# frozen_string_literal: true

module Squishling
  class Error < StandardError; end

  # A programming or setup mistake (missing instructions/schema, non-strict schema, unknown model,
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

  # The LLM call itself failed (rate limit, server error, timeout, connection) after RubyLLM's own
  # HTTP retries. The original exception is available as #cause.
  class LLMError < Error; end
end
