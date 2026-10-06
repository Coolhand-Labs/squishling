# frozen_string_literal: true

module Squishling
  # The elastic path: sends a squished method's inputs through RubyLLM with structured output.
  class Invoker
    INPUT_NOTE = <<~NOTE
      The input is a JSON object. "arguments" holds the values passed to this operation; "context", when
      present, holds additional state about the caller. Respond only with JSON matching the required schema.
    NOTE

    def initialize(definition, receiver, inputs)
      @definition = definition
      @receiver = receiver
      @inputs = inputs
    end

    def call
      instructions = @definition.instructions(@receiver)
      schema = @definition.schema
      raise ConfigurationError, "#{@definition.label} has no instructions" if instructions.nil? || instructions.empty?
      raise ConfigurationError, "#{@definition.label} has no output_schema" unless schema

      chat = build_chat
      chat.with_instructions("#{instructions}\n\n#{INPUT_NOTE}")
      chat.with_schema(schema.llm_schema)
      Params.apply(chat, @definition.params)

      response = ask(chat, JSON.generate(payload))
      attempts = 0
      loop do
        attempts += 1
        data, errors = parse(response.content)
        errors = schema.validate(data) if errors.empty?
        return schema.build(data, squished: true) if errors.empty?

        if attempts > Squishling.config.max_retries
          raise InvalidOutputError.new(errors:, raw: response.content, attempts:)
        end

        response = ask(chat, retry_message(errors))
      end
    end

    private

    def build_chat
      RubyLLM.chat(**chat_options)
    rescue RubyLLM::ModelNotFoundError, RubyLLM::ConfigurationError => e
      raise ConfigurationError, "#{@definition.label}: #{e.message}"
    end

    # Transient HTTP failures are already retried by RubyLLM (config.max_retries); anything that
    # still fails is surfaced as an LLMError rather than retried again here. A 400 means the request
    # we built is invalid (an unsupported param, a schema the provider rejects), so it's a setup
    # mistake: a fallback would otherwise hide it on every call.
    def ask(chat, message)
      chat.ask(message)
    rescue RubyLLM::ConfigurationError, RubyLLM::UnauthorizedError, RubyLLM::ForbiddenError => e
      raise ConfigurationError, "#{@definition.label}: #{e.class}: #{e.message}"
    rescue RubyLLM::BadRequestError => e
      raise ConfigurationError, "#{@definition.label}: the provider rejected the request (#{e.message})#{params_hint}"
    rescue RubyLLM::Error, Faraday::Error => e
      raise LLMError, "#{@definition.label}: #{e.class}: #{e.message}"
    end

    # Models missing from RubyLLM's registry (e.g. newly released ones) are only usable when a
    # provider is named, so RubyLLM is told to assume they exist.
    def chat_options
      model = @definition.model
      provider = @definition.provider
      options = { model:, provider: }.compact
      options[:assume_model_exists] = true if model && provider && !known_model?(model, provider)
      options
    end

    def known_model?(model, provider)
      RubyLLM.models.find(model, provider)
      true
    rescue RubyLLM::ModelNotFoundError
      false
    end

    def params_hint
      params = @definition.params
      return "" if params.empty?

      ". Check params #{params.inspect}; reasoning models often reject sampling params such as temperature and top_p"
    end

    def payload
      body = { arguments: Schema.jsonify(@inputs) }
      names = @definition.context_names
      body[:context] = Schema.jsonify(names.to_h { |name| [name, context_value(name)] }) if names.any?
      body
    end

    def context_value(name)
      return @receiver.send(name) if @receiver.respond_to?(name, true)

      @receiver.instance_variable_get(:"@#{name}")
    end

    # RubyLLM parses structured output itself and leaves the raw string when that fails, so
    # content is a Hash on success, or a String/nil when the model refused, was cut off, or
    # ignored the schema.
    def parse(content)
      return [nil, ["response was empty"]] if content.nil? || (content.is_a?(String) && content.strip.empty?)
      return [content, []] unless content.is_a?(String)

      [JSON.parse(strip_code_fence(content)), []]
    rescue JSON::ParserError => e
      [nil, ["response was not valid JSON (#{e.message.lines.first&.strip})"]]
    end

    # Models without native structured output sometimes wrap JSON in a markdown code fence.
    def strip_code_fence(text)
      text[/\A\s*```(?:json)?\s*\n(.*?)\n\s*```\s*\z/m, 1] || text
    end

    def retry_message(errors)
      "Your previous response did not match the required schema:\n- #{errors.join("\n- ")}\n" \
        "Respond again with corrected JSON only."
    end
  end
end
