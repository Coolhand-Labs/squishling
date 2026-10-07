# frozen_string_literal: true

module Squishling
  # Generation params (temperature, thinking, max_output_tokens, top_p, ...) layered config -> class -> method.
  module Params
    THINKING_KEYS = %i[effort budget display].freeze

    # Request keys Squishling or RubyLLM own. Provider options are merged into the request last,
    # overriding RubyLLM's defaults, so these would silently replace the model, the conversation,
    # or the strict output format.
    RESERVED_KEYS = %i[
      model messages input instructions contents system system_instruction stream stream_options store include
      response_format text output_config tools tool_choice schema
    ].freeze

    module_function

    # Validates and symbolizes one layer. nil values are kept so a layer can unset an inherited key.
    def normalize(params, label)
      raise ConfigurationError, "#{label} must be a Hash, got #{params.class}" unless params.is_a?(Hash)

      params = params.transform_keys(&:to_sym)
      reserved = params.keys & RESERVED_KEYS
      if reserved.any?
        raise ConfigurationError, "#{label}: #{reserved.join(', ')} can't be set through params " \
                                  "(controlled by Squishling/RubyLLM; use model:/provider:/output_schema)"
      end
      params[:thinking] = normalize_thinking(params[:thinking], label) unless params[:thinking].nil?
      params.freeze
    end

    # Later layers override earlier ones key by key; nil removes the key (back to the provider default).
    def resolve(*layers)
      layers.compact.reduce({}) { |merged, layer| merged.merge(layer) }.compact
    end

    # Portable settings use RubyLLM's dedicated setters, which translate them for each provider;
    # everything else is merged into the provider request as-is.
    def apply(chat, params)
      rest = params.except(:temperature, :thinking, :max_output_tokens)
      chat.with_temperature(params[:temperature]) if params.key?(:temperature)
      chat.with_max_output_tokens(params[:max_output_tokens]) if params.key?(:max_output_tokens)
      apply_thinking(chat, params[:thinking]) if params.key?(:thinking)
      chat.with_provider_options(rest) if rest.any?
      chat
    end

    # true: the model's default thinking; false: off; a Hash: { effort:, budget:, display: }.
    def apply_thinking(chat, thinking)
      thinking.is_a?(Hash) ? chat.with_thinking(**thinking) : chat.with_thinking(thinking)
    end

    def normalize_thinking(thinking, label)
      return thinking if [true, false].include?(thinking)

      thinking = thinking.transform_keys(&:to_sym) if thinking.is_a?(Hash)
      unless thinking.is_a?(Hash) && thinking.any? && (thinking.keys - THINKING_KEYS).empty? && !thinking.value?(nil)
        raise ConfigurationError,
          "#{label}: thinking must be true, false, or a Hash with :effort, :budget and/or :display, " \
          "got #{thinking.inspect}"
      end

      thinking
    end
  end
end
