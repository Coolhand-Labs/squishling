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

      chat = RubyLLM.chat(**chat_options)
      chat.with_instructions("#{instructions}\n\n#{INPUT_NOTE}")
      chat.with_schema(schema.llm_schema)

      response = chat.ask(JSON.generate(payload))
      retries = 0
      loop do
        data, errors = parse(response.content)
        errors = schema.validate(data) if errors.empty?
        return schema.build(data, squished: true) if errors.empty?

        raise InvalidOutputError.new(errors:, raw: response.content) if retries >= Squishling.config.max_retries

        retries += 1
        response = chat.ask(retry_message(errors))
      end
    end

    private

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

    def parse(content)
      return [content, []] unless content.is_a?(String)

      [JSON.parse(content), []]
    rescue JSON::ParserError => e
      [nil, ["response was not valid JSON (#{e.message})"]]
    end

    def retry_message(errors)
      "Your previous response did not match the required schema:\n- #{errors.join("\n- ")}\n" \
        "Respond again with corrected JSON only."
    end
  end
end
