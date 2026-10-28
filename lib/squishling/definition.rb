# frozen_string_literal: true

module Squishling
  # A squished method's settings, with per-method overrides falling back to class-level defaults.
  # `for_call` layers one call's `squish!` overrides on top.
  class Definition
    # Matches the keys a squish! context: Hash may use.
    NAME_KEY = ->(key) { key.is_a?(String) || key.is_a?(Symbol) }

    # One attempt on RubyLLM's default model, when no level declares a model.
    DEFAULT_STEP = { model: nil, attempts: 1, forward_rejected: true }.freeze

    attr_reader :klass, :name, :call_context, :handed_off

    def initialize(klass:, name:, purpose: nil, append_to_purpose: nil, output_schema: nil, model: nil,
      provider: nil, params: nil, harness: nil, predicate: nil, fallback: nil, validator: nil, squawk: nil,
      squawk_on: nil, budget: nil, call_context: {}, handed_off: false)
      @klass = klass
      @name = name
      @purpose = purpose
      @append_to_purpose = append_to_purpose
      @output_schema = output_schema
      @model = model
      @provider = provider
      @params = params
      @harness = harness
      @predicate = predicate
      @fallback = fallback
      @validator = validator
      @squawk = squawk
      @squawk_on = squawk_on
      @budget = budget || {}
      @call_context = call_context
      @handed_off = handed_off
    end

    # This definition with one call's overrides on top. The output schema, predicate, fallback, and validator
    # can't be overridden: the call must still return the method's result type.
    def for_call(purpose: nil, append_to_purpose: nil, context: nil, model: nil, escalation: nil,
      provider: nil, params: nil, harness: nil, max_total_output_tokens: nil, max_total_input_tokens: nil)
      call_path = ModelPath.declare(model, escalation, "#{label} squish!")
      raise ConfigurationError, "#{label}: squish! provider: needs a model: or escalation:" if provider && !call_path
      unless context.nil? || (context.is_a?(Hash) && context.each_key.all?(NAME_KEY))
        raise ConfigurationError, "#{label}: squish! context: must be a Hash with String or Symbol keys"
      end

      appended = Appendices.normalize(append_to_purpose, "#{label} squish!") unless append_to_purpose.nil?
      call_params = params && Params.normalize(params, "#{label} squish! params")
      call_harness = Harness.normalize(harness, "#{label} squish!") unless harness.nil?
      call_budget = Budget.build("#{label} squish!", output: max_total_output_tokens, input: max_total_input_tokens)
      self.class.new(
        klass:, name:, output_schema: @output_schema, predicate: @predicate, fallback: @fallback,
        validator: @validator, squawk: @squawk, squawk_on: @squawk_on,
        purpose: purpose || @purpose,
        append_to_purpose: [*@append_to_purpose, *appended],
        model: call_path || @model, provider: call_path ? provider : @provider,
        # merge, not Params.resolve: a nil at the method level must still unset the class's key.
        params: call_params ? (@params || {}).merge(call_params) : @params,
        harness: call_harness || @harness, budget: @budget.merge(call_budget),
        call_context: @call_context.merge((context || {}).transform_keys(&:to_sym)),
        handed_off: true # only squish! builds a definition this way; it is not part of a declared one
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
    # or escalation, or a single attempt on the adapter's default model. A provider travels with the model declared
    # at the same level, so a per-method Anthropic model never inherits a class-level OpenAI provider. Models
    # tied on priority are rotated by this method's call count (see Rotation). Steps whose include_when: is falsy
    # for this call's inputs are left out, so a tier rotates only between its eligible models.
    def escalation_path(receiver, inputs)
      config = Squishling.config
      entries, provider = [[@model, @provider], [klass.squishling_model_path, klass.squishling_provider],
                           [config.default_model_path, config.default_provider]].find(&:first)
      declared = entries || [DEFAULT_STEP]
      eligible = ModelPath.eligible(declared, receiver, inputs, label)
      # Counted when the declared path rotates (so a call that excludes some models doesn't skew the others'
      # rotation) or when this call's eligible steps do (an excluded rotate: false step no longer pins its tier).
      turn = ModelPath.rotating?(declared) || ModelPath.rotating?(eligible) ? Rotation.advance(klass, name) : 0
      ModelPath.steps(eligible, provider:, params:, turn:)
    end

    # How the escalation is used (see Harness): the method's, the class's, the configured default, or :escalation.
    def harness
      @harness || klass.squishling_harness || Squishling.config.default_harness || Harness::DEFAULT
    end

    # Generation params: config defaults, overridden key by key by the class, then by the method.
    def params
      Params.resolve(Squishling.config.default_params, klass.squishling_params, @params)
    end

    # The token limits of one call (see Budget): config defaults, overridden limit by limit by the class, then by the
    # method (and a squish! call).
    def budget
      Budget.resolve(Squishling.config.default_budget, klass.squishling_budget, @budget)
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

    # Which attempts reach the hook (see Squawk): the method's, else the class's, else the configured one.
    def squawk_on
      [@squawk_on, klass.squishling_squawk_on, Squishling.config.squawk_on].find { |on| !on.nil? }
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
      errors = InvalidOutputError::Detail.from(schema.validate(data), :schema) if errors.empty?
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
      [nil, [InvalidOutputError::Detail.new(e.message, :parse)]]
    end

    # The implementation's parameters, beneath the prepended wrappers.
    def parameters
      Wrapper.implementation(klass.instance_method(name))&.parameters || []
    end
  end
end
