# frozen_string_literal: true

module Squishling
  # A developer's callable that Squishling calls with keywords only (squawk, an apprentice's report): checked when it
  # is declared, so a mismatch fails at setup rather than inside a call, and called with only the keywords it
  # declares (all of them when it takes **), so a keyword added later never breaks an existing lambda.
  module KeywordHook
    KEYWORD_TYPES = %i[key keyreq].freeze
    POSITIONAL_TYPES = %i[req opt].freeze
    KEYWORD_CAPTURE_TYPES = %i[key keyreq keyrest].freeze

    module_function

    # The hook itself, or nil/false to inherit/silence. Anything else must respond to call and take keywords only.
    # name is what the messages call it ("squawk"); keywords are the ones it is called with.
    def validate(hook, where, name:, keywords:)
      return hook if hook.nil? || hook == false

      unless hook.respond_to?(:call)
        raise ConfigurationError,
          "#{where} #{name} must respond to call (or be false), got #{Appendices.describe(hook)}"
      end
      check_parameters(parameters(hook), "#{where} #{name}", keywords)
      hook
    end

    def check_parameters(parameters, what, keywords)
      if positional_only?(parameters)
        raise ConfigurationError, "#{what} is called with keywords " \
                                  "(#{keywords.map { |key| "#{key}:" }.join(', ')}), not positional arguments"
      end
      unknown = parameters.filter_map { |type, param| param if type == :keyreq && !keywords.include?(param) }
      raise ConfigurationError, "#{what} requires unknown keyword(s) #{unknown.join(', ')}" if unknown.any?
    end

    # Calls the hook with the keywords it declares, or all of them when it takes **. Exceptions it raises are the
    # developer's own and propagate as-is.
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
