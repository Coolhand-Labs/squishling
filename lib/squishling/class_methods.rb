# frozen_string_literal: true

module Squishling
  # Class-level DSL available to every squishling class.
  module ClassMethods
    DEFAULT_METHOD = :call

    # Set class-wide options in one call:
    #   squishling model: "claude-sonnet-5-5", instructions: "...", output_schema: MySchema
    # Pass provider: alongside model: for models missing from RubyLLM's registry, e.g.
    #   squishling model: "gpt-6-luna", provider: :openai
    # params: are generation params merged over the configured defaults (see Configuration#default_params):
    #   squishling params: { temperature: 0.1, top_p: 0.9 }
    def squishling(model: nil, provider: nil, params: nil, instructions: nil, output_schema: nil)
      @squishling_model = model if model
      @squishling_provider = provider if provider
      @squishling_params = Params.normalize(params, "#{self} params") if params
      self.instructions(instructions) if instructions
      self.output_schema(output_schema) if output_schema
      self
    end

    def squishling_model
      squishling_lookup(:@squishling_model)
    end

    def squishling_provider
      squishling_lookup(:@squishling_provider)
    end

    # Generation params merged down the inheritance chain, so a subclass overrides individual keys.
    def squishling_params
      inherited = superclass.respond_to?(:squishling_params) ? superclass.squishling_params : {}
      inherited.merge(@squishling_params || {})
    end

    # The system prompt. A String, or a Proc evaluated against the instance.
    def instructions(text = nil, &block)
      return squishling_lookup(:@squishling_instructions) if text.nil? && block.nil?

      @squishling_instructions = block || text
    end

    # The output format: a RubyLLM::Schema subclass, a raw JSON Schema Hash, or a
    # RubyLLM::Schema DSL block.
    def output_schema(schema = nil, &block)
      return squishling_lookup(:@squishling_output_schema) if schema.nil? && block.nil?

      @squishling_output_schema = block ? RubyLLM::Schema.create(&block) : schema
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
    # the result (hashes are validated and typed); re-raise to propagate.
    #   squish_fallback { |error, **inputs| { priority: "medium", team: "support" } }
    def squish_fallback(&block)
      @squishling_fallback = block
    end

    def squishling_fallback
      squishling_lookup(:@squishling_fallback)
    end

    # Instance state (attributes or instance variables) to send to the LLM alongside the arguments.
    def squish_context(*names)
      (@squishling_context_names ||= []).concat(names.map(&:to_sym))
    end

    def squishling_context_names
      inherited = superclass.respond_to?(:squishling_context_names) ? superclass.squishling_context_names : []
      (inherited + (@squishling_context_names || [])).uniq
    end

    # Make methods elastic. Each may override the class-level settings:
    #   squish :triage, instructions: "...", model: "...", provider: :openai, when: ->(**) { true },
    #                   fallback: ->(error, **) { { priority: "medium" } } do
    #     string :priority
    #   end
    def squish(*names, instructions: nil, output_schema: nil, model: nil, provider: nil, params: nil, when: nil,
      fallback: nil, &schema_block)
      schema = schema_block ? RubyLLM::Schema.create(&schema_block) : output_schema
      params &&= Params.normalize(params, "#{self} squish params")
      options = { instructions:, output_schema: schema, model:, provider:, params:,
                  predicate: binding.local_variable_get(:when), fallback: }.compact

      names.map(&:to_sym).each do |name|
        (@squishling_methods ||= {})[name] = options
        @squishling_wrapper.wrap(name)
      end
    end

    def squished_methods
      inherited = superclass.respond_to?(:squished_methods) ? superclass.squished_methods : { DEFAULT_METHOD => {} }
      inherited.merge(@squishling_methods || {})
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

    # Each class gets its own prepended wrapper so overrides in subclasses are routed too.
    def squishling_install_wrapper
      @squishling_wrapper = Wrapper.new
      prepend(@squishling_wrapper)

      squished_methods.each_key { |name| @squishling_wrapper.wrap(name) }
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
