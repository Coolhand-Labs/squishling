# frozen_string_literal: true

module Squishling
  # A squished method's settings, with per-method overrides falling back to class-level defaults.
  # `for_call` layers one call's `squish!` overrides on top.
  class Definition
    # Matches the keys a squish! context: Hash may use.
    NAME_KEY = ->(key) { key.is_a?(String) || key.is_a?(Symbol) }

    attr_reader :klass, :name, :call_context

    def initialize(klass:, name:, purpose: nil, append_to_purpose: nil, output_schema: nil, model: nil,
      provider: nil, params: nil, predicate: nil, fallback: nil, validator: nil, squawk: nil, call_context: {})
      @klass = klass
      @name = name
      @purpose = purpose
      @append_to_purpose = append_to_purpose
      @output_schema = output_schema
      @model = model
      @provider = provider
      @params = params
      @predicate = predicate
      @fallback = fallback
      @validator = validator
      @squawk = squawk
      @call_context = call_context
    end

    # This definition with one call's overrides on top. The output schema, predicate, fallback, and validator
    # can't be overridden: the call must still return the method's result type.
    def for_call(purpose: nil, append_to_purpose: nil, context: nil, model: nil, escalation: nil,
      provider: nil, params: nil)
      call_path = ModelPath.declare(model, escalation, "#{label} squish!")
      raise ConfigurationError, "#{label}: squish! provider: needs a model: or escalation:" if provider && !call_path
      unless context.nil? || (context.is_a?(Hash) && context.each_key.all?(NAME_KEY))
        raise ConfigurationError, "#{label}: squish! context: must be a Hash with String or Symbol keys"
      end

      appended = Appendices.normalize(append_to_purpose, "#{label} squish!") unless append_to_purpose.nil?
      call_params = params && Params.normalize(params, "#{label} squish! params")
      self.class.new(
        klass:, name:, output_schema: @output_schema, predicate: @predicate, fallback: @fallback,
        validator: @validator, squawk: @squawk,
        purpose: purpose || @purpose,
        append_to_purpose: [*@append_to_purpose, *appended],
        model: call_path || @model, provider: call_path ? provider : @provider,
        # merge, not Params.resolve: a nil at the method level must still unset the class's key.
        params: call_params ? (@params || {}).merge(call_params) : @params,
        call_context: @call_context.merge((context || {}).transform_keys(&:to_sym))
      )
    end

    def label
      "#{klass}##{name}"
    end

    # The system prompt: the purpose, then each append_to_purpose section.
    def purpose(receiver)
      value = @purpose || klass.purpose
      value = receiver.instance_exec(&value) if value.is_a?(Proc)
      return value if value.nil? || value.empty?

      [value, *Appendices.render(append_to_purpose, receiver, label)].join("\n\n")
    end

    def append_to_purpose
      Appendices.resolve(klass.squishling_append_to_purpose + (@append_to_purpose || []))
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
      entries ||= [{ model: nil, attempts: 1, forward_rejected: true }]
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

    # The observability hook: the method's, else the class's, else the configured one. `false` at a level
    # silences the levels above it.
    def squawk
      [@squawk, klass.squishling_squawk, Squishling.config.squawk].find { |hook| !hook.nil? } || nil
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

    # Deterministic and fallback return values: with an output_schema, every value is validated and
    # typed like an LLM result. Without one, the value passes through untouched.
    def coerce(value)
      schema ? build_result(value, squished: false) : value
    end

    # A result of this schema's own class passes through; any other result is re-validated via to_h.
    def build_result(attrs, squished:)
      raise ConfigurationError, "#{label} has no output_schema" unless schema
      return attrs if schema.result_class && attrs.is_a?(schema.result_class)

      attrs = attrs.to_h if attrs.is_a?(Result::Instance)
      data, errors = jsonify_return(attrs)
      errors = schema.validate(data) if errors.empty?
      raise InvalidOutputError.new(errors:, raw: attrs, source: "Deterministic") if errors.any?

      schema.build(data, squished:)
    end

    # Map positional and keyword arguments onto the original method's parameter names. A positional with no
    # name (a destructuring parameter, or one beyond the declared parameters) is sent as arg0, arg1, ...
    def bind_arguments(args, kwargs)
      positional = args.dup
      bound = {}
      unnamed = 0

      parameters.each do |type, param|
        case type
        when :req, :opt
          next if positional.empty?

          value = positional.shift
          if param
            bound[param] = value
          else
            bound[:"arg#{unnamed}"] = value
            unnamed += 1
          end
        when :rest
          bound[param.nil? || param == :* ? :args : param] = positional.shift(positional.size)
        end
      end
      positional.each_with_index { |value, index| bound[:"arg#{unnamed + index}"] = value }

      bound.merge(kwargs)
    end

    private

    # Values JSON can't represent (NaN, Infinity, cycles) are invalid output, not a raw JSON error.
    def jsonify_return(attrs)
      [Schema.jsonify(attrs), []]
    rescue JSON::GeneratorError, JSON::NestingError => e
      [nil, [e.message]]
    end

    # The implementation's parameters, beneath the prepended wrappers.
    def parameters
      Wrapper.implementation(klass.instance_method(name))&.parameters || []
    end
  end
end
