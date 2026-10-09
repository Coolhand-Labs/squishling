# frozen_string_literal: true

module Squishling
  # A squished method's settings, with per-method overrides falling back to class-level defaults.
  class Definition
    attr_reader :klass, :name

    def initialize(klass:, name:, instructions: nil, output_schema: nil, model: nil, provider: nil, params: nil,
      predicate: nil, fallback: nil, validator: nil)
      @klass = klass
      @name = name
      @instructions = instructions
      @output_schema = output_schema
      @model = model
      @provider = provider
      @params = params
      @predicate = predicate
      @fallback = fallback
      @validator = validator
    end

    def label
      "#{klass}##{name}"
    end

    def instructions(receiver)
      value = @instructions || klass.instructions
      value.is_a?(Proc) ? receiver.instance_exec(&value) : value
    end

    def schema
      raw = @output_schema || klass.output_schema
      raw && Schema.for(raw)
    end

    # One ModelPath::Step per attempt, from the first level (method, class, or config) that declares a model
    # or escalation, or a single attempt on RubyLLM's default model. A provider travels with the model declared
    # at the same level, so a per-method Anthropic model never inherits a class-level OpenAI provider.
    def escalation_path
      config = Squishling.config
      entries, provider = [[@model, @provider], [klass.squishling_model_path, klass.squishling_provider],
                           [config.default_model_path, config.default_provider]].find(&:first)
      entries ||= [{ model: nil, attempts: 1 }]
      ModelPath.steps(entries, provider:, params:)
    end

    # Generation params: config defaults, overridden key by key by the class, then by the method.
    def params
      Params.resolve(Squishling.config.default_params, klass.squishling_params, @params)
    end

    # Extra output checks run on schema-valid LLM results (see ClassMethods#squish_validate).
    def validator
      @validator || klass.squishling_validator
    end

    def context_names
      klass.squishling_context_names
    end

    def squish?(receiver, inputs)
      predicate = @predicate || klass.squishling_predicate
      return false unless predicate

      receiver.instance_exec(**inputs, &predicate) ? true : false
    end

    # Runs the elastic path. When the LLM fails (InvalidOutputError or LLMError) and a fallback is
    # declared, the fallback's return value is used instead, coerced like a deterministic return.
    def invoke_llm(receiver, inputs)
      Invoker.new(self, receiver, inputs).call
    rescue InvalidOutputError, LLMError => e
      handler = @fallback || klass.squishling_fallback
      raise unless handler

      Squishling.config.logger&.warn("[Squishling] #{label} LLM failed, using fallback: #{e.message}")
      coerce(receiver.instance_exec(e, **inputs, &handler))
    end

    # Deterministic return values: hashes are validated and turned into the typed result;
    # anything else (including an already-built result) passes through.
    def coerce(value)
      value.is_a?(Hash) && schema ? build_result(value, squished: false) : value
    end

    def build_result(attrs, squished:)
      raise ConfigurationError, "#{label} has no output_schema" unless schema
      return attrs if attrs.is_a?(Result::Instance)

      data = Schema.jsonify(attrs)
      errors = schema.validate(data)
      raise InvalidOutputError.new(errors:, raw: attrs, source: "Deterministic") if errors.any?

      schema.build(data, squished:)
    end

    # Map positional and keyword arguments onto the original method's parameter names.
    def bind_arguments(args, kwargs)
      positional = args.dup
      bound = {}

      parameters.each do |type, param|
        case type
        when :req, :opt
          bound[param] = positional.shift unless positional.empty? || param.nil?
        when :rest
          bound[param.nil? || param == :* ? :args : param] = positional.shift(positional.size)
        end
      end
      positional.each_with_index { |value, index| bound[:"arg#{index}"] = value }

      bound.merge(kwargs)
    end

    private

    # The first implementation beneath the prepended wrappers (instance_method resolves to the wrapper).
    def parameters
      method = klass.instance_method(name)
      method = method.super_method while method&.owner.is_a?(Wrapper)
      method ? method.parameters : []
    end
  end
end
