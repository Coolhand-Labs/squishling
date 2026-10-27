# frozen_string_literal: true

module Squishling
  # Checks squished classes without making a request: what can only otherwise fail on a method's first call (its
  # output schema and typed result, its callables' keywords) and the settings the layers resolve to. Collects every
  # problem rather than stopping at the first. See Squishling.verify.
  class Verifier
    # Checks one squished method's Definition. Each check returns messages, or raises what the call would.
    class MethodCheck
      CHECKS = %i[schema declarations harness callables].freeze

      def initialize(definition)
        @definition = definition
      end

      def problems
        CHECKS.flat_map { |check| run(check) }
      end

      private

      def run(check)
        Array(send(check)).map { |message| problem(message) }
      rescue ConfigurationError, ArgumentError => e
        [problem(e.message)]
      end

      def problem(message)
        Verification::Problem.new(label: @definition.label, message:)
      end

      # The output schema, its typed result (the Data class a call returns), and the JSON Schema itself.
      def schema
        schema = @definition.schema
        messages = []
        messages << "has no output_schema" unless schema
        messages << "has no purpose" unless @definition.purpose_declared?
        return messages unless schema

        schema.result_class
        messages + JSONSchemer.schema(schema.json_schema).validate_schema.map { |error| error["error"] }
      end

      # The escalation, generation params, and squawk this method resolves to across method, class, and config.
      def declarations
        steps = @definition.declared_path.first.reject { |step| step[:model].nil? }
        ModelPath.from_escalation(steps, "#{@definition.label} escalation") if steps.any?
        Params.normalize(@definition.params, "#{@definition.label} params")
        Squawk.validate(@definition.squawk, @definition.label)
        []
      end

      def harness
        harness = @definition.harness
        messages = []
        unless Harness::Registry.fetch(harness.type).equal?(harness.klass)
          messages << "harness #{harness.type.inspect} was unregistered or replaced after it was declared"
        end
        messages << "the judge needs an adapter that supports judgments" if unsupported_judgment?(harness)
        messages
      end

      def unsupported_judgment?(harness)
        judge = harness.options[:judge]
        judge.is_a?(Hash) && judge[:type] == :judgment && !Squishling.config.resolved_adapter.judgments?
      rescue ConfigurationError
        false # no usable adapter: reported once, as the adapter's own problem
      end

      # Callables the method's inputs are passed to as keywords: include_when: of each step, and squish_when.
      def callables
        names, open = @definition.input_names
        gates = @definition.declared_path.first.filter_map do |step|
          [step[:include_when], "escalation step #{step[:model].inspect} include_when:"] if step[:include_when]
        end
        gates << [@definition.predicate, "squish_when"] if @definition.predicate
        gates.flat_map { |callable, what| KeywordCheck.messages(callable, names, open).map { "#{what} #{_1}" } }
      end
    end

    # Whether a Proc called as instance_exec(**inputs, &proc) accepts the inputs.
    module KeywordCheck
      module_function

      # Messages for how the proc can't be called with the inputs. open: any keyword may be an input (the method
      # takes **), so none can be known.
      def messages(callable, inputs, open)
        return ["must be a Proc, got #{callable.inspect}"] unless callable.is_a?(Proc)
        return [] if open

        parameters = callable.parameters
        [missing_keywords(parameters, inputs), unaccepted_keywords(callable, parameters, inputs),
         missing_positionals(callable, parameters, inputs)].compact
      end

      def missing_keywords(parameters, inputs)
        missing = parameters.filter_map { |type, name| name if type == :keyreq } - inputs
        return if missing.empty?

        "requires #{keywords(missing)}, which #{missing.one? ? 'is not an input' : 'are not inputs'} of the method"
      end

      # A lambda with no positional parameters, or a proc that names keywords, raises on a keyword it doesn't take.
      # Other procs and positional lambdas receive the keywords as a Hash, or ignore them.
      def unaccepted_keywords(callable, parameters, inputs)
        types = parameters.map(&:first)
        return if types.include?(:keyrest) || !strict?(callable, types)

        unaccepted = inputs - parameters.filter_map { |type, name| name if Squawk::KEYWORD_TYPES.include?(type) }
        return if unaccepted.empty?

        "doesn't accept #{keywords(unaccepted)}, which the method takes as input when a caller passes it (add **)"
      end

      # A lambda's required positional parameters get the keywords as one Hash, or nothing when there are none or
      # the lambda names keywords itself.
      def missing_positionals(callable, parameters, inputs)
        return unless callable.lambda?

        types = parameters.map(&:first)
        required = types.count(:req)
        given = types.intersect?(%i[key keyreq keyrest]) || inputs.empty? ? 0 : 1
        return unless required > given

        "takes #{required} positional argument(s), but is called with keywords only"
      end

      def strict?(callable, types)
        keywords = types.intersect?(Squawk::KEYWORD_TYPES)
        callable.lambda? ? keywords || !types.intersect?(%i[req opt rest]) : keywords
      end

      def keywords(names)
        names.map { |name| "#{name}:" }.join(", ")
      end
    end

    def initialize(classes)
      classes.each { |klass| check_squished!(klass) }
      @classes = classes
    end

    def call
      Verification::Report.new(adapter_problems + @classes.flat_map { |klass| class_problems(klass) })
    end

    private

    def check_squished!(klass)
      return if klass.is_a?(Class) && klass.include?(Squishling)

      raise ConfigurationError, "#{klass.inspect} doesn't include Squishling"
    end

    # The configured adapter, or RubyLLM's, must be usable.
    def adapter_problems
      Squishling.config.resolved_adapter
      []
    rescue ConfigurationError => e
      [Verification::Problem.new(label: "adapter", message: e.message)]
    end

    def class_problems(klass)
      klass.squished_methods.keys.flat_map do |name|
        definition = klass.squishling_definition(name)
        next [] if unused_default?(definition)

        MethodCheck.new(definition).problems
      end
    end

    # Every class has the default method (call) squished, whether or not it uses it.
    def unused_default?(definition)
      definition.name == ClassMethods::DEFAULT_METHOD && !definition.implemented? && definition.schema.nil?
    rescue ConfigurationError, ArgumentError
      false
    end
  end
end
