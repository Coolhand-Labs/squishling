# frozen_string_literal: true

module Squishling
  # Class-level DSL available to every squishling class.
  module ClassMethods
    DEFAULT_METHOD = :call
    MODEL_OVERRIDES = %i[model escalation provider].freeze

    # Set class-wide options in one call:
    #   squishling model: "claude-sonnet-5-5", purpose: "...", output_schema: MySchema
    # model: is a single attempt; escalation: is a list of models tried in order (see ModelPath):
    #   squishling escalation: [{ model: "claude-haiku-4-5", attempts: 2 }, "claude-sonnet-5-5", "claude-opus-5-5"]
    # Pass provider: alongside model: for models missing from RubyLLM's registry, e.g.
    #   squishling model: "gpt-7-preview", provider: :openai
    # provider: needs a model: or escalation: (declared on the class), and a subclass's model never inherits its
    # parent's provider.
    # params: are generation params merged over the configured defaults (see Configuration#default_params):
    #   squishling params: { temperature: 0.1, top_p: 0.9 }
    # append_to_purpose: adds sections after the purpose (see #append_to_purpose):
    #   squishling append_to_purpose: ["The Ruby that handles well-formed input:", self]
    # harness: chooses how the escalation is used (see Harness):
    #   squishling harness: :judged_squishsum
    # squawk: is called after every LLM attempt with the raw output (see Configuration#squawk); false silences
    # an inherited one:
    #   squishling squawk: ->(output:, metadata:, error:) { Tracer.record(output, metadata, error) }
    def squishling(model: nil, escalation: nil, provider: nil, params: nil, harness: nil, purpose: nil,
      append_to_purpose: nil, output_schema: nil, squawk: nil)
      path = ModelPath.declare(model, escalation, to_s)
      # A provider belongs to the model declared at the same level. Without a model here it would apply to
      # nothing (the model comes from the config or a parent class), so it is an error unless this class already
      # declared its own.
      if provider && !path && !instance_variable_defined?(:@squishling_model_path)
        raise ConfigurationError, "#{self}: provider: needs a model: or escalation: declared on this class"
      end

      # Stored (even as nil) whenever a model is, so a subclass that declares its own model never inherits a
      # provider meant for its parent's.
      @squishling_model_path = path if path
      @squishling_provider = provider if provider || path
      @squishling_params = Params.normalize(params, "#{self} params") if params
      @squishling_harness = Harness.normalize(harness, to_s) unless harness.nil?
      self.purpose(purpose) if purpose
      self.append_to_purpose(append_to_purpose) unless append_to_purpose.nil?
      self.output_schema(output_schema) if output_schema
      @squishling_squawk = Squawk.validate(squawk, to_s) unless squawk.nil?
      self
    end

    def squishling_squawk
      squishling_lookup(:@squishling_squawk)
    end

    # The class's (or nearest ancestor's) model or escalation, as normalized steps.
    def squishling_model_path
      squishling_lookup(:@squishling_model_path)
    end

    def squishling_provider
      squishling_lookup(:@squishling_provider)
    end

    def squishling_harness
      squishling_lookup(:@squishling_harness)
    end

    # Generation params merged down the inheritance chain, so a subclass overrides individual keys.
    def squishling_params
      squishling_inherited(:squishling_params, {}).merge(@squishling_params || {})
    end

    # The system prompt. A String, or a Proc evaluated against the instance.
    def purpose(text = nil, &block)
      return squishling_lookup(:@squishling_purpose) if text.nil? && block.nil?

      @squishling_purpose = block || text
    end

    # Sections appended to the system prompt after the purpose, added to by subclasses, `squish`, and
    # `squish!`. Items: Strings; a class or module (`self` for this class) or a method (`instance_method(:call)`),
    # sent as its Ruby source; or a Proc evaluated against the instance. `false` drops inherited items.
    #   append_to_purpose "Here is the Ruby that parses well-formed invoices:", self
    #   append_to_purpose { "This client's invoices are in #{currency}." }
    def append_to_purpose(*items, &block)
      items = items.first if items.size == 1 && items.first.is_a?(Array)
      items += [block] if block
      (@squishling_append_to_purpose ||= []).concat(Appendices.normalize(items, "#{self} append_to_purpose"))
      self
    end

    # Every level's items in declaration order, `false` markers included (see Appendices.resolve).
    def squishling_append_to_purpose
      squishling_inherited(:squishling_append_to_purpose, []) + (@squishling_append_to_purpose || [])
    end

    # The output format: a Schematist::Schema subclass (RubyLLM::Schema with the ruby_llm-schema shim),
    # a raw JSON Schema Hash, or a Schematist DSL block.
    def output_schema(schema = nil, &block)
      return squishling_lookup(:@squishling_output_schema) if schema.nil? && block.nil?

      @squishling_output_schema = block ? Schematist::Schema.create(&block) : schema
    end

    # Routing predicate, called with the method's inputs as keywords and evaluated against the
    # instance. Truthy sends the call to the LLM; falsy runs the Ruby implementation.
    def squish_when(&block)
      @squishling_predicate = block
    end

    def squishling_predicate
      squishling_lookup(:@squishling_predicate)
    end

    # Called with the error and the method's inputs (as keywords) when the LLM path fails with an
    # InvalidOutputError or LLMError, evaluated against the instance. Its return value is used as
    # the result (validated against the schema and typed like a deterministic return); re-raise to propagate.
    #   squish_fallback { |error, **inputs| { priority: "medium", team: "support" } }
    def squish_fallback(&block)
      @squishling_fallback = block
    end

    def squishling_fallback
      squishling_lookup(:@squishling_fallback)
    end

    # Extra checks on a result that already matches the schema, called with the typed result and the method's
    # inputs (as keywords), evaluated against the instance. Return nil (or true, "", []) to accept, or error
    # message(s) to reject the output and move on to the next attempt, with the messages fed back:
    #   squish_validate { |result, **| "total must equal the line items" if result.total != result.line_items.sum }
    # A dry-validation style result (responding to success? and errors) is accepted too.
    # It judges LLM output. With `both_paths: true` (or config.validate_both_paths) it judges the Ruby path's return
    # too, and a Ruby return rejected by it or by the schema goes to the LLM, which gets the draft and the problems:
    #   squish_validate(both_paths: true) { |result, **| ProposalChecks.problems(result) }
    # `both_paths: false` keeps a class to the LLM whatever the config says; `both_paths:` alone, with no block,
    # changes only that and keeps the check declared above.
    def squish_validate(both_paths: nil, &block)
      unless [nil, true, false].include?(both_paths)
        raise ConfigurationError, "#{self} squish_validate both_paths: must be true or false, got #{both_paths.inspect}"
      end

      @squishling_validator = block if block || both_paths.nil?
      @squishling_both_paths = both_paths unless both_paths.nil?
    end

    def squishling_validator
      squishling_lookup(:@squishling_validator)
    end

    # true, false, or nil (defer to config.validate_both_paths), from the class or its nearest ancestor.
    def squishling_both_paths
      squishling_lookup(:@squishling_both_paths)
    end

    # Names the errors the Ruby implementation may raise that the LLM should take over from, like a rescue clause.
    # Names add up across calls and down the chain.
    # The LLM gets the call with the error in its context and answers in the same result type:
    #   squish_rescue AcmeParser::ParseError, Timeout::Error
    # Nothing is rescued unless named. A return rejected under `squish_validate both_paths: true` is handed off too.
    # The options are squish!'s, minus context:, and apply to every such hand-off. append_to_purpose adds sections
    # after the built-in note (`false` drops what is above it):
    #   squish_rescue append_to_purpose: ["The Ruby that drafted the answer:", self], model: "claude-opus-5-5"
    def squish_rescue(*classes, append_to_purpose: nil, purpose: nil, model: nil, escalation: nil, provider: nil,
      params: nil, harness: nil)
      overrides = { append_to_purpose:, purpose:, model:, escalation:, provider:, params:, harness: }.compact
      label = "#{self} squish_rescue"
      raise ConfigurationError, "#{label} needs error classes or options" if classes.empty? && overrides.empty?

      list = RubyPath.normalize_rescue(classes, label) unless classes.empty?
      Definition.new(klass: self, name: DEFAULT_METHOD).for_call(**overrides, via: "squish_rescue") # fails now
      if append_to_purpose
        overrides[:append_to_purpose] = Appendices.normalize(append_to_purpose, "#{self} squish_rescue")
      end
      @squishling_rescue = [*@squishling_rescue, *list].uniq.freeze if list
      @squishling_rescue_overrides = merge_rescue_overrides(@squishling_rescue_overrides || {}, overrides)
      self
    end

    # Every class named by this class, its ancestors, and each squish_rescue call: they add up, like rescue clauses.
    def squishling_rescue
      [*squishling_inherited(:squishling_rescue, []), *@squishling_rescue].uniq
    end

    # The options every hand-off carries, merged down the chain: a subclass's append_to_purpose adds to its
    # parent's, and a model or escalation of its own replaces the parent's.
    def squishling_rescue_overrides
      own = @squishling_rescue_overrides || {}
      merge_rescue_overrides(squishling_inherited(:squishling_rescue_overrides, {}), own)
    end

    # Instance state (attributes or instance variables) to send to the LLM alongside the arguments.
    def squish_context(*names)
      (@squishling_context_names ||= []).concat(names.map(&:to_sym))
    end

    def squishling_context_names
      (squishling_inherited(:squishling_context_names, []) + (@squishling_context_names || [])).uniq
    end

    # Make methods elastic. Each may override the class-level settings:
    #   squish :triage, purpose: "...", escalation: %w[claude-haiku-4-5 claude-sonnet-5-5], when: ->(**) { true },
    #                   fallback: ->(error, **) { { priority: "medium" } }, append_to_purpose: [...],
    #                   validate: ->(result, **) { "team is required" if result.team.empty? },
    #                   harness: :squishsum, squawk: ->(output:, error:, **) { Tracer.record(output, error) } do
    #     string :priority
    #   end
    def squish(*names, purpose: nil, append_to_purpose: nil, output_schema: nil, model: nil, escalation: nil,
      provider: nil, params: nil, harness: nil, when: nil, fallback: nil, validate: nil, squawk: nil, &schema_block)
      schema = schema_block ? Schematist::Schema.create(&schema_block) : output_schema
      model = ModelPath.declare(model, escalation, "#{self} squish")
      raise ConfigurationError, "#{self} squish: provider: needs a model: or escalation:" if provider && !model

      params &&= Params.normalize(params, "#{self} squish params")
      harness = Harness.normalize(harness, "#{self} squish") unless harness.nil?
      unless append_to_purpose.nil?
        append_to_purpose = Appendices.normalize(append_to_purpose, "#{self} squish append_to_purpose")
      end
      squawk = Squawk.validate(squawk, "#{self} squish")
      options = { purpose:, append_to_purpose:, output_schema: schema, model:, provider:, params:, harness:,
                  predicate: binding.local_variable_get(:when), fallback:, validator: validate, squawk: }.compact

      names.map(&:to_sym).each do |name|
        (@squishling_methods ||= {})[name] = options
        @squishling_wrapper.wrap(name)
      end
    end

    def squished_methods
      squishling_inherited(:squished_methods, { DEFAULT_METHOD => {} }).merge(@squishling_methods || {})
    end

    def squishling_definition(name)
      options = squished_methods.fetch(name.to_sym) { raise Error, "#{self}##{name} is not squished" }
      Definition.new(klass: self, name: name.to_sym, **options)
    end

    # Service-object shortcut: InvoiceParser.call(...) == InvoiceParser.new.call(...)
    def call(...)
      new.call(...)
    end

    def inherited(subclass)
      super
      subclass.send(:squishling_install_wrapper)
    end

    private

    # A model or escalation declared lower replaces the one above it (with its provider), never joins it.
    def merge_rescue_overrides(above, below)
      above = above.except(*MODEL_OVERRIDES) if below.keys.intersect?(%i[model escalation])
      above.merge(below) { |key, earlier, later| key == :append_to_purpose ? [*earlier, *later] : later }
    end

    # Each class gets its own prepended wrapper so overrides in subclasses are routed too.
    def squishling_install_wrapper
      @squishling_wrapper = Wrapper.new
      prepend(@squishling_wrapper)

      squished_methods.each_key { |name| @squishling_wrapper.wrap(name) }
    end

    # The superclass's merged setting, or the default at the top of the chain.
    def squishling_inherited(reader, default)
      superclass.respond_to?(reader) ? superclass.public_send(reader) : default
    end

    def squishling_lookup(ivar)
      klass = self
      while klass.is_a?(ClassMethods)
        return klass.instance_variable_get(ivar) if klass.instance_variable_defined?(ivar)

        klass = klass.superclass
      end
      nil
    end
  end
end
