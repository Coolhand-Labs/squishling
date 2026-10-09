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

    # Makes each attempt of the escalation (Definition#escalation_path) until an output passes the schema and
    # the squish_validate check. Consecutive attempts on the same step continue the same conversation, so the
    # model sees what it got wrong; a new step starts a fresh chat told about the last rejected output.
    def call
      @instructions = @definition.instructions(@receiver)
      @schema = @definition.schema
      raise ConfigurationError, "#{@definition.label} has no instructions" if @instructions.nil? || @instructions.empty?
      raise ConfigurationError, "#{@definition.label} has no output_schema" unless @schema

      path = @definition.escalation_path
      input = JSON.generate(payload)
      chat = nil
      rejected = nil # [raw content, errors] of the last invalid output
      models = []

      path.each.with_index(1) do |step, attempt|
        models << step.model
        last = attempt == path.size
        if chat && step == path[attempt - 2]
          message = retry_message(rejected.last)
        else
          chat = start_chat(step)
          message = rejected ? escalation_message(input, *rejected) : input
        end

        begin
          response = ask(chat, message, step)
        rescue LLMError => e
          raise if last

          # The failed request may be half-recorded in this chat, so the next attempt starts a fresh one.
          chat = nil
          log_failure(attempt, path, e.message)
          next
        end

        result, errors = check(response.content)
        return result if errors.empty?

        raise InvalidOutputError.new(errors:, raw: response.content, attempts: attempt, models:) if last

        rejected = [response.content, errors]
        log_failure(attempt, path, errors.join("; "))
      end
    end

    private

    def start_chat(step)
      chat = build_chat(step)
      chat.with_instructions("#{@instructions}\n\n#{INPUT_NOTE}")
      chat.with_schema(@schema.llm_schema)
      apply_params(chat, step.params)
      chat
    end

    def build_chat(step)
      RubyLLM.chat(**chat_options(step))
    rescue RubyLLM::ModelNotFoundError, RubyLLM::ConfigurationError => e
      raise ConfigurationError, "#{@definition.label}: #{e.message}"
    end

    # RubyLLM validates some settings locally (e.g. an impossible thinking budget for the model)
    # and raises ArgumentError before any request is sent.
    def apply_params(chat, params)
      Params.apply(chat, params)
    rescue ArgumentError => e
      raise ConfigurationError, "#{@definition.label}: invalid params #{params.inspect} (#{e.message})"
    end

    # Transient HTTP failures are already retried by RubyLLM (RubyLLM.config.max_retries); anything
    # that still fails is surfaced as an LLMError, which moves on to the next attempt of the
    # escalation (or propagates from the last one). A 400 means the request we built is invalid (an
    # unsupported param, a schema the provider rejects), so it's a setup mistake: escalating or a
    # fallback would otherwise hide it on every call.
    def ask(chat, message, step)
      chat.ask(message)
    rescue RubyLLM::ConfigurationError, RubyLLM::UnauthorizedError, RubyLLM::ForbiddenError => e
      raise ConfigurationError, "#{@definition.label}: #{e.class}: #{e.message}"
    rescue RubyLLM::BadRequestError => e
      raise ConfigurationError,
        "#{@definition.label}: the provider rejected the request (#{e.message})#{params_hint(step.params)}"
    rescue RubyLLM::Error, Faraday::Error => e
      raise LLMError, "#{@definition.label}: #{e.class}: #{e.message}"
    end

    # Models missing from RubyLLM's registry (e.g. newly released ones) are only usable when a
    # provider is named, so RubyLLM is told to assume they exist.
    def chat_options(step)
      model = step.model
      provider = step.provider
      options = { model:, provider: }.compact
      options[:assume_model_exists] = true if model && provider && !known_model?(model, provider)
      options
    end

    def known_model?(model, provider)
      RubyLLM.models.find(model, provider:)
      true
    rescue RubyLLM::ModelNotFoundError
      false
    end

    def params_hint(params)
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

    # Parses and validates a response: [typed result, []] when it passes, [nil or result, errors] otherwise.
    def check(content)
      data, errors = parse(content)
      errors = @schema.validate(data) if errors.empty?
      return [nil, errors] if errors.any?

      result = @schema.build(data, squished: true)
      [result, validator_errors(result)]
    end

    # Runs the squish_validate check, if any. Exceptions it raises are the user's own and propagate as-is.
    def validator_errors(result)
      validator = @definition.validator
      return [] unless validator

      value = @receiver.instance_exec(result, **@inputs, &validator)
      case value
      when nil, true then []
      when false then ["the output was rejected by squish_validate"]
      when String, Array then Array(value).flatten.compact.map(&:to_s).reject { |message| message.strip.empty? }
      else
        return contract_errors(value) if value.respond_to?(:success?) && value.respond_to?(:errors)

        raise ConfigurationError, "#{@definition.label}: squish_validate must return nil, true, false, a String, " \
                                  "an Array of Strings, or a validation result, got #{value.class}"
      end
    end

    # A dry-validation style result: errors.to_h is { key => ["message", ...] }, nested for nested keys.
    def contract_errors(value)
      return [] if value.success?

      errors = value.errors
      errors = errors.to_h if !errors.is_a?(Array) && errors.respond_to?(:to_h)
      messages = errors.is_a?(Hash) ? flatten_messages(errors) : Array(errors).map(&:to_s)
      messages.empty? ? ["the output was rejected by squish_validate"] : messages
    end

    def flatten_messages(errors, prefix = nil)
      errors.flat_map do |key, value|
        path = [prefix, key].compact.join(".")
        next flatten_messages(value, path) if value.is_a?(Hash)

        Array(value).map { |message| path.empty? ? message.to_s : "#{path} #{message}" }
      end
    end

    def retry_message(errors)
      "Your previous response was rejected:\n- #{errors.join("\n- ")}\nRespond again with corrected JSON only."
    end

    # The first message to a fresh chat after an earlier model's output was rejected.
    def escalation_message(input, raw, errors)
      previous = raw.is_a?(String) ? raw : JSON.generate(raw)
      previous = "(an empty response)" if previous.strip.empty? || raw.nil?
      "#{input}\n\nA previous attempt at this request returned:\n#{previous}\n" \
        "It was rejected:\n- #{errors.join("\n- ")}\nRespond with corrected JSON only."
    end

    def log_failure(attempt, path, reason)
      step = path[attempt - 1]
      next_step = path[attempt]
      action = next_step == step ? "retrying" : "escalating to #{model_name(next_step)}"
      Squishling.config.logger&.warn("[Squishling] #{@definition.label} attempt #{attempt} of #{path.size} " \
                                     "(#{model_name(step)}) failed, #{action}: #{reason}")
    end

    def model_name(step)
      step.model || "RubyLLM default model"
    end
  end
end
