# frozen_string_literal: true

module Squishling
  class Harness
    # The base of every harness: the built-ins, and your own. Subclass it, declare the options it takes, define
    # call, and register it (Squishling.register_harness):
    #
    #   class Tiebreaker < Squishling::Harness::Base
    #     option :tiebreaker, :step, required: true
    #
    #     def call(run, tiebreaker:)
    #       first, second = run.samples(run.stages.first(2))
    #       run.agree?(first, second) ? first : run.escalate(tiebreaker)
    #     end
    #   end
    #   Squishling.register_harness(:tiebreaker, Tiebreaker)
    #
    # call gets a Run (the primitives that ask for samples, escalate, and judge) and the validated options as
    # keywords, and returns the accepted typed result, or raises Squishling::InvalidOutputError (a
    # DisagreementError when samples disagreed) or Squishling::LLMError, which squish_fallback handles.
    class Base
      Option = Data.define(:name, :type, :required)

      # The kinds of parameter that can receive the run, call's first argument.
      RUN_PARAMETERS = %i[req opt rest].freeze
      KEYWORD_PARAMETERS = %i[key keyreq].freeze
      REQUIRED_PARAMETERS = %i[req keyreq].freeze

      class << self
        # Declares an option: its name, one of OptionTypes::TYPES (or a callable that normalizes the value, see
        # OptionTypes), and whether it must be given. A harness is declared with { type: :name, option_name: value },
        # and the options are checked up front.
        def option(name, type, required: false)
          unless OptionTypes.type?(type)
            raise ConfigurationError, "option #{name.inspect}: type must be one of #{OptionTypes::TYPES.join(', ')} " \
                                      "or a callable taking (value, label, name), got #{type.inspect}"
          end

          raise ConfigurationError, "declare options on a subclass of Harness::Base, not on Base" if equal?(Base)
          if name.to_sym == :type
            raise ConfigurationError, "option :type is taken: it names the harness in a harness Hash"
          end

          own_options[name.to_sym] = Option.new(name: name.to_sym, type:, required: required ? true : false)
        end

        # The declared options by name, including those of the superclass.
        def options
          inherited = equal?(Base) ? {} : superclass.options
          inherited.merge(own_options)
        end

        # The options as given in a harness Hash (without type:): checked and normalized, or ConfigurationError.
        # An option given as nil counts as not given.
        def normalize_options(given, label)
          given = given.transform_keys(&:to_sym)
          unknown = given.keys - options.keys
          raise ConfigurationError, "#{label}: unknown harness option(s) #{unknown.join(', ')}" if unknown.any?

          given = given.compact

          missing = options.values.select { |option| option.required && !given.key?(option.name) }
          if missing.any?
            raise ConfigurationError, "#{label}: harness option(s) #{missing.map(&:name).join(', ')} required"
          end

          normalized = given.to_h do |name, value|
            [name, OptionTypes.check(options.fetch(name).type, value, label, name)]
          end
          validate_options!(normalized, label)
          normalized.freeze
        end

        # Override to check options against each other; raise ConfigurationError (with the label) to reject.
        def validate_options!(_options, _label); end

        # Rejects a class that can't run as the harness registered under name: not a Base subclass, no call,
        # or a call that doesn't take the run and each declared option.
        def check_registrable!(klass, name)
          unless klass.is_a?(Class) && klass <= Base && klass != Base
            raise ConfigurationError, "harness #{name.inspect} must be a subclass of Squishling::Harness::Base, " \
                                      "got #{klass.inspect}"
          end
          if klass.instance_method(:call).owner == Base
            raise ConfigurationError, "harness #{name.inspect} must define call(run, **options)"
          end
          unless klass.public_method_defined?(:call)
            raise ConfigurationError, "harness #{name.inspect}: call must be public"
          end

          check_signature!(klass, name)
        end

        private

        def own_options
          @own_options ||= {}
        end

        def check_signature!(klass, name)
          parameters = klass.instance_method(:call).parameters
          unless RUN_PARAMETERS.include?(parameters.first&.first)
            raise ConfigurationError, "harness #{name.inspect}: call must take the run as its first argument"
          end
          if parameters.count { |type, _| type == :req } > 1
            raise ConfigurationError, "harness #{name.inspect}: call takes the run, then options as keywords only"
          end
          if klass.instance_method(:initialize).parameters.any? { |type, _| REQUIRED_PARAMETERS.include?(type) }
            raise ConfigurationError, "harness #{name.inspect}: a harness is created without arguments, " \
                                      "so initialize can't require any"
          end

          accepted = parameters.filter_map { |type, key| key if KEYWORD_PARAMETERS.include?(type) }
          required = parameters.filter_map { |type, key| key if type == :keyreq }
          # A ** takes every declared option, but not an option's absence.
          missing = parameters.any? { |type, _| type == :keyrest } ? [] : klass.options.keys - accepted
          undeclared = required - klass.options.keys
          # An option that may be left out can't be a required keyword.
          optional = required & klass.options.values.reject(&:required).map(&:name)
          return if missing.empty? && undeclared.empty? && optional.empty?

          problems = [("doesn't take #{missing.join(', ')}" if missing.any?),
                      ("requires undeclared #{undeclared.join(', ')}" if undeclared.any?),
                      ("requires optional #{optional.join(', ')} (give it a default)" if optional.any?)].compact
          raise ConfigurationError, "harness #{name.inspect}: call #{problems.join(' and ')} " \
                                    "(declare each option with option, and take it as a keyword)"
        end
      end

      # The harness itself; subclasses define it.
      def call(_run, **)
        raise ConfigurationError, "#{self.class} must define call(run, **options)"
      end
    end
  end
end
