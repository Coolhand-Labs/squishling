# frozen_string_literal: true

module Squishling
  # Turns a model response into a typed result: parses it, validates it against the schema, and runs the
  # method's squish_validate check.
  class OutputCheck
    def initialize(definition, receiver, inputs)
      @definition = definition
      @receiver = receiver
      @inputs = inputs
    end

    # Parses and validates a response: [typed result, []] when it passes, [nil or result, errors] otherwise.
    # The judge's role skips squish_validate, which checks the operation's output, not a verdict.
    def call(content, prompt)
      data, errors = parse(content)
      errors = prompt.schema.validate(data) if errors.empty?
      return [nil, errors] if errors.any?

      result = prompt.schema.build(data, squished: true)
      [result, prompt.role == :judge ? [] : validator_errors(result)]
    end

    private

    # RubyLLM parses structured output itself and leaves the raw string when that fails, so
    # content is a Hash on success, or a String/nil when the model refused, was cut off, or
    # ignored the schema.
    def parse(content)
      return [nil, ["response was empty"]] if content.nil? || (content.is_a?(String) && content.strip.empty?)
      return [content, []] unless content.is_a?(String)

      [JSON.parse(strip_code_fence(content)), []]
    rescue JSON::ParserError => e
      [nil, ["response was not valid JSON#{parse_position(e)}"]]
    end

    # The parser's message quotes a snippet of the response, which must not reach error messages or logs
    # (the raw output lives only in InvalidOutputError#raw), so only the position is kept.
    def parse_position(error)
      position = error.message.strip.match(/ at line (\d+) column (\d+)\z/)
      position ? " (at line #{position[1]} column #{position[2]})" : ""
    end

    # Models without native structured output sometimes wrap JSON in a markdown code fence.
    def strip_code_fence(text)
      text[/\A\s*```(?:json)?\s*\n(.*?)\n\s*```\s*\z/m, 1] || text
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
  end
end
