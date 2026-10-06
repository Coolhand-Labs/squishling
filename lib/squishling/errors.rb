# frozen_string_literal: true

module Squishling
  class Error < StandardError; end

  # A programming or setup mistake (missing instructions/schema, non-strict schema, unknown model,
  # missing API key). Never retried and never passed to squish_fallback.
  class ConfigurationError < Error; end

  # Output that didn't match the schema: from the LLM after all retries, or from the deterministic path.
  class InvalidOutputError < Error
    attr_reader :errors, :raw, :attempts

    def initialize(errors:, raw: nil, source: "LLM", attempts: nil)
      @errors = errors
      @raw = raw
      @attempts = attempts
      tries = attempts ? " after #{attempts} attempt#{'s' unless attempts == 1}" : ""
      super("#{source} output did not match the output schema#{tries}: #{errors.join('; ')}")
    end
  end

  # The LLM call itself failed (rate limit, server error, timeout, connection) after RubyLLM's own
  # HTTP retries. The original exception is available as #cause.
  class LLMError < Error; end
end
