# frozen_string_literal: true

module Squishling
  module Testing
    # Runs the parts of a squished method that don't need a model, for unit tests: the output checks, the fallback,
    # and the prompt. Each takes the method's arguments as args: and keywords (as the method is called), and a
    # receiver: for a class whose constructor takes arguments.
    module Direct
      class << self
        # The messages squish_validate and the output schema reject this reply with ([] when it would be accepted).
        def validate(klass, reply, method: :call, receiver: nil, args: [], **kwargs)
          definition = klass.squishling_definition(method)
          schema = definition.schema or raise SetupError, "#{definition.label} has no output_schema"
          inputs = definition.bind_arguments(args, kwargs)
          prompt = Invoker::Prompt.new(instructions: nil, schema:, input: nil, role: nil)
          OutputCheck.new(definition, receiver || klass.new, inputs).call(reply, prompt).last.map(&:message)
        end

        # What squish_fallback returns for this error, typed like any result of the method.
        def fallback_for(klass, error, method: :call, receiver: nil, args: [], **kwargs)
          definition = klass.squishling_definition(method)
          handler = definition.fallback or raise SetupError, "#{definition.label} has no squish_fallback"
          inputs = definition.bind_arguments(args, kwargs)
          definition.coerce((receiver || klass.new).instance_exec(error, **inputs, &handler))
        end

        # The first request a call would make, without making it: { system_prompt:, user_message:, output_schema:,
        # step: } (the step is the ModelPath::Step with the model, provider and params; rotation isn't advanced).
        def preview(klass, method: :call, receiver: nil, args: [], **kwargs)
          definition = klass.squishling_definition(method)
          receiver ||= klass.new
          inputs = definition.bind_arguments(args, kwargs)
          prompt = Invoker.new(definition, receiver, inputs).prompt
          { system_prompt: prompt.instructions, user_message: prompt.input,
            output_schema: prompt.schema.llm_schema["schema"],
            step: definition.escalation_path(receiver, inputs, advance: false).first }
        end
      end
    end
  end
end
