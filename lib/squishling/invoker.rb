# frozen_string_literal: true

module Squishling
  # The elastic path: sends a squished method's inputs through the configured adapter with structured output.
  class Invoker
    INPUT_NOTE = <<~NOTE
      The input is a JSON object. "arguments" holds the values passed to this operation; "context", when
      present, holds additional state about the caller. Respond only with JSON matching the required schema.
    NOTE

    # The most of a rejected output that is forwarded to the next escalation step.
    MAX_FORWARDED_CHARS = 4_000

    # One escalation's request: the system prompt, the output Schema, and the first user message. The judge's
    # role (:judge) skips squish_validate and names the judge in errors and logs.
    Prompt = Data.define(:instructions, :schema, :input, :role)

    def initialize(definition, receiver, inputs)
      @definition = definition
      @receiver = receiver
      @inputs = inputs
    end

    # Everything a Run needs of the call: the prompt, the payload it was built from, and the purpose text.
    Built = Data.define(:prompt, :payload, :purpose)

    # Runs the harness (Definition#harness) over a Run of the call: the harness decides how the escalation is
    # used, and what it returns is checked against the output schema's type.
    def call
      built = build
      harness = @definition.harness
      run = Run.new(definition: @definition, receiver: @receiver, inputs: @inputs, prompt: built.prompt,
        payload: built.payload, purpose: built.purpose, harness:)
      accepted(harness.klass.new.call(run, **harness.options), run, harness)
    end

    # The first request the call would make (system prompt, output schema, user message), without making it.
    def prompt
      build.prompt
    end

    private

    def build
      purpose = @definition.purpose(@receiver)
      schema = @definition.schema
      raise ConfigurationError, "#{@definition.label} has no purpose" if purpose.nil? || purpose.empty?
      raise ConfigurationError, "#{@definition.label} has no output_schema" unless schema

      body = payload
      prompt = Prompt.new(instructions: "#{purpose}\n\n#{INPUT_NOTE}", schema:, input: JSON.generate(body), role: nil)
      Built.new(prompt:, payload: body, purpose:)
    end

    # What a harness returns must be a result its run produced: validated output, typed like the deterministic
    # path's. One built by hand, or a hash, would skip the schema and squish_validate.
    def accepted(value, run, harness)
      return value if run.produced?(value)

      raise ConfigurationError, "#{@definition.label}: the #{harness.type} harness must return a result from " \
                                "its run (escalate, samples, or a judge's pick), got #{value.class}"
    end

    # Only the arguments, the declared squish_context names, and a squish! call's context leave the process.
    def payload
      body = { arguments: Schema.jsonify(describe(@inputs)) }
      context = @definition.context_names.to_h { |name| [name, context_value(name)] }.merge(@definition.call_context)
      body[:context] = Schema.jsonify(describe(context)) if context.any?
      body
    end

    # Exceptions are sent as their class and message. Plain JSON would send only the message, and with
    # json/add/exception loaded it would also send the backtrace, which exposes file paths. path is the Hashes and
    # Arrays being walked: one that contains itself is a ConfigurationError rather than a SystemStackError.
    def describe(value, path = [])
      case value
      when Exception then { class: exception_class_name(value.class), message: value.message }
      when Hash then within(value, path) { |inner| value.transform_values { |item| describe(item, inner) } }
      when Array then within(value, path) { |inner| value.map { |item| describe(item, inner) } }
      else value
      end
    end

    def within(container, path)
      if path.any? { |ancestor| ancestor.equal?(container) }
        raise ConfigurationError, "#{@definition.label}: an argument or context value contains itself, " \
                                  "so it can't be sent as JSON"
      end

      yield path + [container]
    end

    # An anonymous error class (Class.new(StandardError)) is named after its closest named ancestor.
    def exception_class_name(klass)
      klass = klass.superclass until klass.name
      klass.name
    end

    def context_value(name)
      return @receiver.send(name) if @receiver.respond_to?(name, true)

      @receiver.instance_variable_get(:"@#{name}")
    end
  end
end
