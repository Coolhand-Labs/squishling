# frozen_string_literal: true

module Squishling
  class Error < StandardError; end

  # A programming or setup mistake (missing purpose/schema, non-strict schema, unknown model,
  # missing API key). Never retried and never passed to squish_fallback.
  class ConfigurationError < Error; end

  # The provider answered a request with HTTP 400 (or another 4xx that isn't a credentials, model, or redirect
  # problem). Still a ConfigurationError: never retried, escalated, or passed to a fallback. The provider's message is
  # never repeated; the machine-readable status and code its error body carries are, when they are plain tokens
  # (e.g. "INVALID_ARGUMENT", "invalid_request_error"). Both are nil when the body has none.
  class RequestRejectedError < ConfigurationError
    attr_reader :provider_status, :provider_code

    def initialize(message, provider_status: nil, provider_code: nil)
      @provider_status = provider_status
      @provider_code = provider_code
      super(message)
    end
  end

  # Output that didn't match the schema (or a squish_validate check): from the LLM after every attempt in the
  # escalation, or from the deterministic path.
  class InvalidOutputError < Error
    # models: the model ids tried, one per attempt (nil entries mean the adapter's default model).
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

  # A harness's samples (the squishsum harnesses', or a custom one's) were valid but didn't agree, and either no
  # judge was declared (verdict nil) or the judge rejected both (verdict :neither, with its reason). candidates
  # holds the typed results, so a squish_fallback can still return one of them, and raw all of them as Hashes.
  # models names the model behind each role (sample a, sample b, then the judge if one ran), not one entry per
  # attempt; attempts is nil.
  class DisagreementError < InvalidOutputError
    attr_reader :candidates, :verdict, :reason

    # detail: is text Squishling wrote itself (a judgment model's choice and probability) and is added to the
    # message. A chat judge's reason is model-written and can quote the input, so it stays out of the message
    # (and the logs); read it from #reason.
    def initialize(candidates:, verdict: nil, reason: nil, detail: nil, models: nil)
      @candidates = candidates
      @verdict = verdict
      @reason = reason
      error = verdict ? "the judge rejected both samples" : "the two samples disagreed"
      error += " (#{detail})" if detail
      super(errors: [error], raw: candidates.map(&:to_h), models:)
    end
  end

  # The LLM call itself failed (rate limit, server error, timeout, connection) after the
  # adapter's own HTTP retries. The original exception is available as #cause.
  class LLMError < Error; end
end
