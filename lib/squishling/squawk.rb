# frozen_string_literal: true

module Squishling
  # The opt-in observability hook: a callable run after every LLM attempt with the attempt's raw output, so
  # it can be sent somewhere (an error tracker, a tracing tool). It's the one sanctioned way for model output
  # to leave the process; nothing runs unless one is configured.
  module Squawk
    KEYWORD_TYPES = %i[key keyreq].freeze
    POSITIONAL_TYPES = %i[req opt].freeze
    KEYWORD_CAPTURE_TYPES = %i[key keyreq keyrest].freeze
    KEYWORDS = %i[output metadata error].freeze

    module_function

    # The hook itself, or nil/false to inherit/silence. Anything else must respond to call and take keywords
    # only, which is checked here so a mismatch fails at setup, not inside the first attempt.
    def validate(hook, where)
      return hook if hook.nil? || hook == false

      unless hook.respond_to?(:call)
        raise ConfigurationError, "#{where} squawk must respond to call (or be false), got #{hook.inspect}"
      end
      if positional_only?(parameters(hook))
        raise ConfigurationError,
          "#{where} squawk is called with keywords (output:, metadata:, error:), not positional arguments"
      end
      unknown = parameters(hook).filter_map { |type, name| name if type == :keyreq && !KEYWORDS.include?(name) }
      raise ConfigurationError, "#{where} squawk requires unknown keyword(s) #{unknown.join(', ')}" if unknown.any?

      hook
    end

    # Calls the hook with the keywords it declares, or all of them when it takes **, so new metadata fields
    # never break an existing lambda. Exceptions it raises are the user's own and propagate as-is.
    def call(hook, **payload)
      parameters = parameters(hook)
      payload = payload.slice(*parameters.filter_map { |type, name| name if KEYWORD_TYPES.include?(type) }) \
        unless parameters.any? { |type, _| type == :keyrest }
      hook.call(**payload)
    end

    # Positional parameters, or a bare splat, would receive the keywords as a Hash (or not at all).
    def positional_only?(parameters)
      types = parameters.map(&:first)
      types.intersect?(POSITIONAL_TYPES) || (types.include?(:rest) && !types.intersect?(KEYWORD_CAPTURE_TYPES))
    end

    def parameters(hook)
      (hook.is_a?(Proc) || hook.is_a?(Method) ? hook : hook.method(:call)).parameters
    end
  end
end
