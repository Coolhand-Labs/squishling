# frozen_string_literal: true

module Squishling
  # Generation params (temperature, thinking, top_p, max_tokens, ...) layered config -> class -> method.
  module Params
    THINKING_KEYS = %i[effort budget].freeze

    # Request keys Squishling or RubyLLM own. Params are deep-merged into the provider request last,
    # so these would silently replace the model, the conversation, or the strict output format.
    RESERVED_KEYS = %i[
      model messages contents system system_instruction stream stream_options
      response_format output_config tools tool_choice schema
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

    # :temperature and :thinking use RubyLLM's dedicated setters (which apply provider-specific
    # handling); everything else is deep-merged into the provider request as-is.
    def apply(chat, params)
      rest = params.except(:temperature, :thinking)
      chat.with_temperature(params[:temperature]) if params.key?(:temperature)
      chat.with_thinking(**params[:thinking]) if params.key?(:thinking)
      chat.with_params(**rest) if rest.any?
      chat
    end

    def normalize_thinking(thinking, label)
      thinking = thinking.transform_keys(&:to_sym) if thinking.is_a?(Hash)
      unless thinking.is_a?(Hash) && thinking.any? && (thinking.keys - THINKING_KEYS).empty?
        raise ConfigurationError,
          "#{label}: thinking must be a Hash with :effort and/or :budget, got #{thinking.inspect}"
      end

      thinking
    end
  end
end
