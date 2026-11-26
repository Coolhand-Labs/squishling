# frozen_string_literal: true

module Squishling
  # The opt-in observability hook: a callable run after every LLM attempt (or only the rejected and retried
  # ones, see squawk_on:) with the attempt's raw output, so it can be sent somewhere (an error tracker, a
  # tracing tool). It's the one sanctioned way for model output to leave the process; nothing runs unless one
  # is configured. A call that a token budget or a disagreement stops gets one more report, with the error and no
  # output (metadata's stopped:), since neither has an attempt of its own.
  module Squawk
    KEYWORD_TYPES = KeywordHook::KEYWORD_TYPES
    POSITIONAL_TYPES = KeywordHook::POSITIONAL_TYPES
    KEYWORDS = %i[output metadata error].freeze
    # The squawk_on: conditions, each answering "does the hook run for this attempt?" from the attempt's 1-based
    # number (the one its metadata carries), its error (nil when accepted), and whether it is the last one. A stopped
    # call's report has an error and is final, so it passes every condition whatever its attempt number (0 or more).
    CONDITIONS = {
      all: ->(_attempt, _error, _final) { true },
      rejections: ->(_attempt, error, _final) { !error.nil? },
      retries: ->(attempt, error, _final) { !error.nil? || attempt > 1 },
      final: ->(_attempt, _error, final) { final }
    }.freeze
    ON = CONDITIONS.keys.freeze

    module_function

    # Which attempts reach the hook (squawk_on:): one condition or a list of them, or nil to inherit. :all is
    # every attempt, :rejections only the ones that errored, :retries those plus any accepted attempt after the
    # first, and :final the last attempt the escalation allows (metadata's final:), however it ended; an earlier
    # accepted attempt is not final. The report of a stopped call is final and has an error, so every
    # condition lets it through. A list runs the hook when any of them holds.
    def validate_on(value, where)
      return value if value.nil?

      conditions = value.is_a?(Array) ? value : [value]
      unless conditions.any? && conditions.all? { |condition| CONDITIONS.key?(condition) }
        raise ConfigurationError,
          "#{where} squawk_on must be one or a list of #{ON.map(&:inspect).join(', ')}, got #{value.inspect}"
      end

      value.is_a?(Array) ? value.dup.freeze : value
    end

    def report?(on, attempt, error, final)
      Array(on).any? { |condition| CONDITIONS.fetch(condition).call(attempt, error, final) }
    end

    # The hook itself, or nil/false to inherit/silence. Anything else must respond to call and take keywords
    # only, which is checked here so a mismatch fails at setup, not inside the first attempt.
    def validate(hook, where)
      KeywordHook.validate(hook, where, name: "squawk", keywords: KEYWORDS)
    end

    # Calls the hook with the keywords it declares, or all of them when it takes **, so new metadata fields
    # never break an existing lambda. Exceptions it raises are the user's own and propagate as-is.
    def call(hook, **)
      KeywordHook.call(hook, **)
    end
  end
end
