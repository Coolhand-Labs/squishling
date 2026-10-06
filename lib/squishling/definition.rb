# frozen_string_literal: true

module Squishling
  # A squished method's settings, with per-method overrides falling back to class-level defaults.
  class Definition
    attr_reader :klass, :name

    def initialize(klass:, name:, instructions: nil, output_schema: nil, model: nil, provider: nil, predicate: nil)
      @klass = klass
      @name = name
      @instructions = instructions
      @output_schema = output_schema
      @model = model
      @provider = provider
      @predicate = predicate
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

    def model
      model_and_provider.first
    end

    def provider
      model_and_provider.last
    end

    # A provider travels with the model declared at the same level (method, class, or config),
    # so a per-method Anthropic model never inherits a class-level OpenAI provider.
    def model_and_provider
      config = Squishling.config
      [[@model, @provider], [klass.squishling_model, klass.squishling_provider],
       [config.default_model, config.default_provider]].find(&:first) || [nil, nil]
    end

    def context_names
      klass.squishling_context_names
    end

    def squish?(receiver, inputs)
      predicate = @predicate || klass.squishling_predicate
      return false unless predicate

      receiver.instance_exec(**inputs, &predicate) ? true : false
    end

    def invoke_llm(receiver, inputs)
      Invoker.new(self, receiver, inputs).call
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
