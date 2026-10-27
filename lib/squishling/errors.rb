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
    # Added to the message (and the log line) when the last reply was cut off at the output token cap.
    CUTOFF_NOTE = "cut off at the output token limit"

    # One entry of #error_details: the message and where it came from.
    #   :schema      a JSON Schema error; it can name a key the model chose (a disallowed additional property)
    #   :validator   your own squish_validate message, verbatim (so it holds model values only if you interpolate them)
    #   :parse       a message about a response or return value that didn't parse (not valid JSON, empty,
    #                a value JSON can't represent)
    #   :squishling  any other text Squishling or a custom harness wrote
    Detail = Data.define(:message, :source) do
      # One detail per message, all from the same source.
      def self.from(messages, source) = messages.map { |message| new(message, source) }

      def initialize(message:, source:)
        unless Detail::SOURCES.include?(source)
          raise ArgumentError, "unknown error source #{source.inspect} (expected #{Detail::SOURCES.join(', ')})"
        end

        super
      end

      # Whether the message can contain text the model chose, so a sink with its own control syntax should escape
      # it. Your own squish_validate messages are never flagged, even if you interpolate result values into them.
      def model_derived? = source == :schema
    end
    Detail::SOURCES = %i[schema validator parse squishling].freeze

    # models: the model ids tried, one per attempt (nil entries mean the adapter's default model). finish_reason: why
    # the provider stopped on the last attempt (a Symbol such as :stop or :max_tokens; nil when unknown or not from
    # an LLM).
    # errors: Strings, or Details; a String counts as :squishling text.
    attr_reader :errors, :error_details, :raw, :attempts, :models, :finish_reason

    def initialize(errors:, raw: nil, source: "LLM", attempts: nil, models: nil, finish_reason: nil)
      @error_details = errors.map { |error| error.is_a?(Detail) ? error : Detail.new(error.to_s, :squishling) }
      @error_details.freeze
      @errors = @error_details.map(&:message).freeze
      @raw = raw
      @attempts = attempts
      @models = models
      @finish_reason = finish_reason
      tries = attempts ? " after #{attempts} attempt#{'s' unless attempts == 1}" : ""
      cutoff = " (#{CUTOFF_NOTE})" if truncated?
      super("#{source} output was invalid#{tries}: #{@errors.join('; ')}#{cutoff}")
    end

    # Whether the last reply was cut off at the output token cap, so raising max_output_tokens (leaving room for any
    # thinking budget) is the fix rather than changing the prompt or validator.
    def truncated?
      finish_reason == :max_tokens
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

  # The call spent its token budget (max_total_output_tokens or max_total_input_tokens) before any attempt was
  # accepted, so no further request was made. limit names the budget that was reached, max its value, and used the
  # tokens spent so far ({ input_tokens:, output_tokens: }). errors starts with the budget line, then the validation
  # errors of the last rejected output, which is in raw (nil when no output had been rejected, e.g. the samples were
  # valid but the judge could not run). Like any InvalidOutputError it goes to squish_fallback.
  class BudgetExhaustedError < InvalidOutputError
    attr_reader :limit, :max, :used

    def initialize(limit:, max:, used:, errors: [], raw: nil, attempts: nil, models: nil)
      @limit = limit
      @max = max
      @used = used
      spent = used.fetch(:"#{limit.to_s.delete_prefix('max_total_')}")
      super(errors: ["token budget exhausted: #{spent} of #{max} #{limit} used", *errors], raw:, attempts:, models:)
    end
  end

  # The LLM call itself failed (rate limit, server error, timeout, connection) after the
  # adapter's own HTTP retries. The original exception is available as #cause.
  class LLMError < Error; end
end
