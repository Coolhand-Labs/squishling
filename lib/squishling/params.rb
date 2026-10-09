# frozen_string_literal: true

module Squishling
  # Generation params (temperature, thinking, max_output_tokens, top_p, ...) layered config -> class -> method.
  module Params
    THINKING_KEYS = %i[effort budget display].freeze

    # Request keys Squishling or RubyLLM own. Provider options are merged into the request last,
    # overriding RubyLLM's defaults, so these would silently replace the model, the conversation,
    # or the strict output format.
    RESERVED_KEYS = %i[
      model messages input inputs instructions contents system system_instruction stream stream_options store include
      response_format text output_config tools tool_choice schema
      outputConfig toolConfig tool_config systemInstruction
    ].freeze

    # Some protocols carry the structured-output format (or tool selection) inside a container that is
    # itself allowed, because it also holds ordinary settings (Gemini's topK, Mistral's top_p, ...). RubyLLM
    # deep-merges provider options, so these nested keys would override the strict format just like the
    # top-level ones. Re-check each protocol's render_payload (ruby_llm protocols/*/chat.rb) on every
    # ruby_llm upgrade.
    GENERATION_CONFIG_RESERVED_KEYS = %i[
      responseMimeType response_mime_type responseSchema response_schema responseJsonSchema response_json_schema
      response_format tools tool_choice toolConfig tool_config
    ].freeze
    COMPLETION_ARGS_RESERVED_KEYS = %i[response_format tools tool_choice].freeze
    NESTED_RESERVED_KEYS = {
      generationConfig: GENERATION_CONFIG_RESERVED_KEYS, # Gemini
      generation_config: GENERATION_CONFIG_RESERVED_KEYS, # Gemini Interactions
      completion_args: COMPLETION_ARGS_RESERVED_KEYS # Mistral Conversations
    }.freeze

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
      reject_nested_reserved!(params, label)
      params[:thinking] = normalize_thinking(params[:thinking], label) unless params[:thinking].nil?
      params.freeze
    end

    # Nested keys are compared as symbols so a string-keyed "responseMimeType" can't slip past the check.
    # A non-Hash container would replace (not merge into) the one RubyLLM builds, wiping the strict format.
    # Validated containers are copied and frozen so they can't be mutated after the check.
    def reject_nested_reserved!(params, label)
      nested = NESTED_RESERVED_KEYS.flat_map do |container, reserved|
        value = params[container]
        next [] if value.nil?
        raise ConfigurationError, "#{label}: #{container} must be a Hash, got #{value.class}" unless value.is_a?(Hash)

        params[container] = value.dup.freeze
        (value.keys.filter_map { |key| key.to_sym if key.respond_to?(:to_sym) } & reserved)
          .map { |key| "#{container}.#{key}" }
      end
      return if nested.empty?

      raise ConfigurationError, "#{label}: #{nested.join(', ')} can't be set through params " \
                                "(controls the strict output format or tools; use output_schema)"
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
