# frozen_string_literal: true

module Squishling
  class Configuration
    # Model used by every squishling class that doesn't declare its own (a single attempt).
    # When neither this nor default_escalation is set, the adapter's own default model is used.
    attr_reader :default_model

    # Models tried in order by every squishling class that doesn't declare its own, e.g.
    #   [{ model: "claude-haiku-4-5", attempts: 2 }, "claude-sonnet-5-5", "claude-opus-5-5"]
    # See ModelPath. default_model and default_escalation set the same thing: assigning one clears the other.
    attr_reader :default_escalation

    # The validated default_model or default_escalation steps (nil when neither is set).
    attr_reader :default_model_path

    # Provider for default_model/default_escalation steps that don't name their own (e.g. :openai). What it means is
    # up to the adapter: the RubyLLM adapter needs it only for models missing from RubyLLM's registry, and the
    # OpenAI-compatible adapter ignores it.
    attr_accessor :default_provider

    # Generation params applied to every call, overridable per class and per method.
    # :temperature, :max_output_tokens and :thinking ({ effort:, budget: }) are portable and translated by the
    # adapter for its provider; any other key (top_p, seed, ...) is passed to the provider as-is.
    attr_reader :default_params

    # Whether requests ask the provider to cache the stable prompt: true (the default), false, or a Hash of options
    # such as { ttl: "1h" } (see Cache). Overridable per class, per method, per escalation step, and per squish! call.
    attr_reader :default_cache

    # How every squishling class that doesn't declare its own harness uses its escalation (see Harness):
    # :escalation (the default), :squishsum, :judged_squishsum, a harness you registered, or a Hash with type: and
    # its options.
    attr_reader :default_harness

    # Most output tokens, and most input tokens, one squished call may use across all its requests (nil, the default,
    # sets no limit). A call that has used this many stops with a BudgetExhaustedError instead of making another
    # attempt; overridable per class, method and squish! call (see Budget).
    attr_reader :default_max_total_output_tokens, :default_max_total_input_tokens

    # Optional Logger for routing and escalation decisions.
    attr_accessor :logger

    # Optional callable run after each LLM attempt (narrowed by squawk_on) with the raw output (see Squawk), e.g.
    #   ->(output:, metadata:, error:) { Tracer.record(output, metadata, error) }
    attr_reader :squawk

    # Which attempts reach the squawk hook: :all (the default), :rejections (attempts that errored), :retries (those
    # plus any accepted attempt after the first), :final (the last attempt the escalation allows), or a list of
    # them. Also settable per class and per method.
    attr_reader :squawk_on

    # Optional around-style hook wrapped around every provider request (see Observer): an object responding to
    # around(call) { ... }, or :coolhand. nil (the default) uses the Coolhand observer when the coolhand gem is
    # loaded and configured, and nothing otherwise; false never wraps.
    attr_reader :observer

    # How Squishling reaches a model (see Adapter): :ruby_llm, :openai_compatible, an adapter you registered, a Hash
    # with type: and that adapter's options, or an adapter instance. nil (the default) uses RubyLLM when the ruby_llm
    # gem is available. Built when assigned, so a mistake fails at setup rather than on the first request.
    attr_reader :adapter

    def initialize
      @adapter = nil
      @detected_adapter = nil
      @adapter_lock = Mutex.new
      @observer = nil
      @default_model = nil
      @default_escalation = nil
      @default_model_path = nil
      @default_provider = nil
      @default_params = {}
      @default_cache = true
      @default_harness = nil
      @logger = nil
      @squawk = nil
      @squawk_on = :all
    end

    def default_model=(model)
      @default_model_path = ModelPath.from_model(model, "default_model")
      @default_escalation = nil
      @default_model = model
    end

    def default_escalation=(escalation)
      @default_model_path = ModelPath.from_escalation(escalation, "default_escalation")
      @default_model = nil
      @default_escalation = escalation
    end

    def adapter=(adapter)
      built = adapter.nil? ? nil : Adapter.build(adapter, "Squishling.configure")
      @adapter_lock.synchronize do
        @adapter = built
        @detected_adapter = nil
      end
    end

    # The adapter requests go through: the configured one, else RubyLLM's (when its gem is available) built on first
    # use. Raises ConfigurationError when there is neither.
    def resolved_adapter
      @adapter_lock.synchronize { @adapter || (@detected_adapter ||= Adapter.detect) }
    end

    def default_max_total_output_tokens=(tokens)
      @default_max_total_output_tokens = Budget.build("default_max_total_output_tokens", output: tokens)[:output]
    end

    def default_max_total_input_tokens=(tokens)
      @default_max_total_input_tokens = Budget.build("default_max_total_input_tokens", input: tokens)[:input]
    end

    # The configured limits as a Budget level.
    def default_budget
      { output: default_max_total_output_tokens, input: default_max_total_input_tokens }.compact
    end

    def squawk=(hook)
      @squawk = Squawk.validate(hook, "Squishling.configure")
    end

    def squawk_on=(on)
      @squawk_on = Squawk.validate_on(on, "Squishling.configure") || :all
    end

    def observer=(observer)
      Observer.validate(observer, "Squishling.configure")
      # A named observer is built now, so a missing gem fails at setup rather than on the first request.
      Observer.resolve(observer) if observer.is_a?(Symbol)
      @observer = observer
    end

    def default_params=(params)
      @default_params = Params.normalize(params, "default_params")
    end

    # nil restores the default (true).
    def default_cache=(cache)
      @default_cache = cache.nil? || Cache.normalize(cache, "default_cache")
    end

    def default_harness=(harness)
      @default_harness = harness.nil? ? nil : Harness.normalize(harness, "default_harness")
    end

    MAX_RETRIES_REMOVED = "max_retries was removed; use default_escalation (or a class/method escalation:) " \
                          "with attempts:, e.g. [{ model: \"claude-haiku-4-5\", attempts: 2 }]"

    # Removed: the escalation decides how many attempts run.
    def max_retries
      raise ConfigurationError, MAX_RETRIES_REMOVED
    end

    def max_retries=(_value)
      raise ConfigurationError, MAX_RETRIES_REMOVED
    end
  end
end
