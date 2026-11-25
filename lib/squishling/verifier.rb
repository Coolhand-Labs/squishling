# frozen_string_literal: true

module Squishling
  # Checks squished classes without making a request: what can only otherwise fail on a method's first call (its
  # output schema and typed result, its callables' keywords) and the settings the layers resolve to. Collects every
  # problem rather than stopping at the first. See Squishling.verify.
  class Verifier
    # Checks one squished method's Definition. Each check returns messages, or raises what the call would.
    class MethodCheck
      CHECKS = %i[schema declarations adapters harness callables apprentice].freeze

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

      # The adapter of every escalation step and of the judge must be configured. The default one (a step or judge that
      # names none) is checked here only when named adapters exist, since otherwise the whole run reports it once.
      def adapters
        names = @definition.declared_path.first.map { |step| step[:adapter] }
        judge = @definition.harness.options[:judge]
        names << judge[:adapter] if judge.is_a?(Hash)
        names = names.compact unless Squishling.config.adapters.any?
        names.uniq.filter_map { |name| adapter_problem(name) }
      end

      # A message when the step's adapter (nil, the default one) can't be used. Not through Testing's override.
      def adapter_problem(name)
        name.nil? ? Squishling.config.resolved_adapter : Squishling.config.named_adapter(name)
        nil
      rescue ConfigurationError => e
        "adapter: #{e.message}"
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
        judge.is_a?(Hash) && judge[:type] == :judgment && !Squishling.config.adapter_for(judge[:adapter]).judgments?
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
        gates << [shadowed_apprentice[:when], "apprentice_mode when:"] if shadowed_apprentice&.dig(:when)
        gates.flat_map { |callable, what| KeywordCheck.messages(callable, names, open).map { "#{what} #{_1}" } }
      end

      # Apprentice mode shadows the Ruby implementation, so a method that declares it needs one. compare: gets the two
      # results, then the inputs as keywords.
      def apprentice
        settings = shadowed_apprentice
        return [] unless settings

        compare = settings[:compare]
        messages = compare ? KeywordCheck.compare_messages(compare, *@definition.input_names) : []
        return messages if @definition.implemented?

        ["apprentice_mode: has no Ruby implementation to run alongside the LLM", *messages]
      end

      # The apprentice settings of a method that can be shadowed, or nil. Declared on a class, they apply only to the
      # methods with a Ruby implementation, so an LLM-only method isn't checked against them; declared on a method,
      # they always apply (and the method must have one).
      def shadowed_apprentice
        settings = @definition.apprentice
        settings if settings && (@definition.apprentice_declared? || @definition.implemented?)
      end
    end

    # Whether a Proc called as instance_exec(**inputs, &proc) accepts the inputs.
    module KeywordCheck
      POSITIONAL_SLOTS = %i[req opt].freeze

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

      # For an apprentice's compare:, a Proc called as instance_exec(ruby, llm, **inputs, &proc).
      def compare_messages(callable, inputs, open)
        parameters = callable.parameters
        messages = compare_positionals(callable, parameters.map(&:first), inputs, open)
        unless open
          messages += [missing_keywords(parameters, inputs), unaccepted_keywords(callable, parameters, inputs)].compact
        end
        messages.map { |message| "apprentice_mode compare: #{message}" }
      end

      # A compare: takes the two results positionally, then the inputs as keywords. A proc, or a lambda that names no
      # keywords, gets the inputs (when the method has some) as one more positional Hash.
      def compare_positionals(callable, types, inputs, open)
        named = types.intersect?(%i[key keyreq keyrest])
        hash = named || open || inputs.empty? ? 0 : 1
        required = types.count(:req)
        if required > 2 + hash
          called = hash == 1 ? "two results and the inputs" : "two results"
          return ["takes #{required} positional arguments, but is called with #{called}"]
        end

        callable.lambda? ? compare_slots(types, named, open || inputs.any?) : []
      end

      # A lambda must take both results, and the inputs either as keywords or (naming none) as a Hash.
      def compare_slots(types, named, keywords)
        slots = types.include?(:rest) ? 3 : types.count { |type| POSITIONAL_SLOTS.include?(type) }
        return ["doesn't take the two results (the Ruby result and the LLM's) as positional arguments"] if slots < 2
        return ["doesn't take the method's inputs as keywords (add **)"] if keywords && !named && slots < 3

        []
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

    # The configured adapter, or RubyLLM's, must be usable, unless named adapters are configured: then the default
    # one is only needed by the steps that use it, which each method's check reports. The named adapters are built
    # when assigned.
    def adapter_problems
      Squishling.config.resolved_adapter unless Squishling.config.adapters.any?
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
