# frozen_string_literal: true

module Squishling
  module Testing
    # Replaces a squished method for the tests of its callers: the method returns (or raises) what the test says and
    # never reaches Squishling, but what it returns is a real typed result, validated against the method's output
    # schema, so the stand-in can't drift from the real result type. Cleared by Testing.reset!.
    module Stubs
      LOCK = Mutex.new
      private_constant :LOCK

      # [class, method name] => callable producing the result, or raising the error
      @active = {}
      # [class, method name] => the module prepended to the class. A prepended module can't be removed, so it stays
      # (inert once its stub is cleared) and keeps its class alive: stub the classes of a suite, not one per test.
      @hooks = {}

      ERRORS = {
        invalid_output: :invalid_output_error, llm_error: :llm_error, configuration: :configuration_error,
        disagreement: :disagreement_error
      }.freeze

      class << self
        # A result of the method's schema, with these attributes (squished: false for one the Ruby path returned).
        def result(klass, attrs, method: :call, squished: true, &)
          definition = klass.squishling_definition(method)
          built = typed(definition, attrs, squished:)
          activate(klass, method, -> { built }, &)
        end

        # The method raises this kind of error: :invalid_output (errors:, raw:, attempts:, models:), :llm_error
        # (message:), :configuration (message:), or :disagreement (candidates:, verdict:, reason:, models:).
        def error(klass, kind, method: :call, **options, &)
          builder = ERRORS.fetch(kind) do
            raise ArgumentError, "unknown error #{kind.inspect} (one of #{ERRORS.keys.map(&:inspect).join(', ')})"
          end
          definition = klass.squishling_definition(method)
          # Built once now, so a mistyped option fails here and not in the code under test.
          send(builder, definition, **options)
          activate(klass, method, -> { raise send(builder, definition, **options) }, &)
        end

        def clear!
          LOCK.synchronize { @active.clear }
        end

        # The stub for a method, called by the module prepended to its class (nil when there is none).
        def stub_for(klass, method)
          LOCK.synchronize { @active[[klass, method]] }
        end

        private

        def activate(klass, method, callable)
          previous = LOCK.synchronize { @active.delete([klass, method]).tap { @active[[klass, method]] = callable } }
          hook(klass, method)
          return klass unless block_given?

          begin
            yield
          ensure
            LOCK.synchronize { previous ? @active[[klass, method]] = previous : @active.delete([klass, method]) }
          end
        end

        # Prepended once per method: calls the stub while there is one, and the real method otherwise.
        def hook(klass, method)
          LOCK.synchronize { @hooks[[klass, method]] ||= build_hook(klass, method) }
        end

        # A Wrapper, so Wrapper.implementation looks past it to the real method (its parameter names name the
        # arguments the model is sent) once the stub is gone.
        def build_hook(klass, method)
          hook = Wrapper.new
          hook.define_method(method) do |*args, **kwargs, &block|
            stub = Stubs.stub_for(klass, method) if instance_of?(klass) # a subclass keeps its own behavior
            stub ? stub.call : super(*args, **kwargs, &block)
          end
          klass.prepend(hook)
          hook
        end

        # The attributes as the method's own typed result, validated by the same path as a Ruby-path return.
        def typed(definition, attrs, squished:)
          definition.build_result(attrs, squished:)
        rescue InvalidOutputError => e
          raise SetupError, "#{definition.label}: the stubbed result doesn't match its output_schema: " \
                            "#{e.errors.join('; ')}"
        rescue ConfigurationError
          raise SetupError, "#{definition.label} has no output_schema to build a result from"
        end

        def invalid_output_error(_definition, errors: ["stubbed invalid output"], raw: nil, attempts: 1, models: nil)
          InvalidOutputError.new(errors: Array(errors), raw:, attempts:, models: models || ([nil] * attempts))
        end

        def llm_error(definition, message: "stubbed LLM failure")
          LLMError.new("#{definition.label}: #{message}")
        end

        def configuration_error(definition, message: "stubbed configuration error")
          ConfigurationError.new("#{definition.label}: #{message}")
        end

        def disagreement_error(definition, candidates:, verdict: nil, reason: nil, models: nil)
          typed = candidates.map { |candidate| typed(definition, candidate, squished: true) }
          DisagreementError.new(candidates: typed, verdict:, reason:, models:)
        end
      end
    end
  end
end
