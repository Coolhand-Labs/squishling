# frozen_string_literal: true

module Squishling
  # The elastic path: sends a squished method's inputs through the configured adapter with structured output.
  class Invoker
    INPUT_NOTE = <<~NOTE
      The input is a JSON object. "arguments" holds the values passed to this operation; "context", when
      present, holds additional state about the caller. Respond only with JSON matching the required schema.
    NOTE

    IMAGE_NOTE = <<~NOTE
      Images are attached to this message. Each {"attached_image": N} value in the input stands for the Nth image.
    NOTE

    DOCUMENT_NOTE = <<~NOTE
      Documents are attached to this message. Each {"attached_document": N} value in the input stands for the Nth document.
    NOTE

    # The most of a rejected output that is forwarded to the next escalation step.
    MAX_FORWARDED_CHARS = 4_000

    # One escalation's request: the system prompt, the output Schema, the first user message, and the files (Images
    # and Documents) that go with it. The judge's role (:judge) skips squish_validate and names the judge in errors
    # and logs.
    Prompt = Data.define(:instructions, :schema, :input, :role, :files) do
      def initialize(instructions:, schema:, input:, role:, files: [])
        super
      end

      def images = files.grep(Image)
      def documents = files.grep(Document)
    end

    # What the system prompt says about the placeholders of the files a call sends.
    def self.file_notes(files)
      "#{IMAGE_NOTE if files.any?(Image)}#{DOCUMENT_NOTE if files.any?(Document)}"
    end

    def initialize(definition, receiver, inputs, call_id: nil)
      @supplied_call_id = call_id
      @definition = definition
      @receiver = receiver
      @inputs = inputs
    end

    # Everything a Run needs of the call: the prompt, the payload it was built from, and the purpose text.
    Built = Data.define(:prompt, :payload, :purpose)

    # Runs the harness (Definition#harness) over a Run of the call: the harness decides how the escalation is
    # used, and what it returns is checked against the output schema's type. A call that ends on the token budget
    # or a disagreement is reported to squawk once here, as the stop no attempt of its own reported.
    # built is what #prepare returned, when the call's request was built ahead (an apprentice builds it on the
    # caller's thread and runs the call on another).
    def call(built = prepare)
      harness = @definition.harness
      @run = Run.new(definition: @definition, receiver: @receiver, inputs: @inputs, prompt: built.prompt,
        payload: built.payload, purpose: built.purpose, harness:, call_id: @supplied_call_id)
      accepted(call_harness(harness, @run), @run, harness)
    end

    # The first request the call would make (system prompt, output schema, user message), without making it.
    def prompt
      prepare.prompt
    end

    # What the call sends, built from the purpose (its procs run here) and the payload (the arguments and the
    # squish_context values, read here).
    def prepare
      purpose = @definition.purpose(@receiver)
      schema = @definition.schema
      raise ConfigurationError, "#{@definition.label} has no purpose" if purpose.nil? || purpose.empty?
      raise ConfigurationError, "#{@definition.label} has no output_schema" unless schema

      body, files = payload
      instructions = "#{purpose}\n\n#{INPUT_NOTE}#{self.class.file_notes(files)}"
      prompt = Prompt.new(instructions:, schema:, input: JSON.generate(body), role: nil, files: files.freeze)
      Built.new(prompt:, payload: body, purpose:)
    end

    # The id of the call #call made (see Observer::Call#call_id), or nil before it started.
    def call_id
      @run&.call_id
    end

    # Where a result #call returned came from (LLMClient::Origin), or nil.
    def origin(result)
      @run&.origin(result)
    end

    private

    def call_harness(harness, run)
      harness.klass.new.call(run, **harness.options)
    rescue BudgetExhaustedError, DisagreementError => e
      run.report_stop(e)
      raise
    end

    # What a harness returns must be a result its run produced: validated output, typed like the deterministic
    # path's. One built by hand, or a hash, would skip the schema and squish_validate.
    def accepted(value, run, harness)
      return value if run.produced?(value)

      raise ConfigurationError, "#{@definition.label}: the #{harness.type} harness must return a result from " \
                                "its run (escalate, samples, or a judge's pick), got #{value.class}"
    end

    # Only the arguments, the declared squish_context names, and a squish! call's context leave the process, once
    # the sanitizers have had them. Returns the JSON body and the files it sends.
    def payload
      context = @definition.context_names.to_h { |name| [name, context_value(name)] }.merge(@definition.call_context)
      tree = { arguments: @inputs }
      tree[:context] = context if context.any?
      Payload.build(tree, @definition.label, sanitizers: @definition.sanitizers, receiver: @receiver)
    end

    def context_value(name)
      return @receiver.send(name) if @receiver.respond_to?(name, true)

      @receiver.instance_variable_get(:"@#{name}")
    end
  end
end
