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

    # Whether the tokens a request reads from the provider's prompt cache count toward max_total_input_tokens: false
    # (the default) leaves them out, true counts them. Tokens written to the cache always count (see Budget).
    attr_reader :budget_counts_cache_reads

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

    # Optional callable run after each LLM attempt (narrowed by squawk_on), and once more when a token budget or a
    # disagreement stops the call, with the raw output (see Squawk), e.g.
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

    # More adapters, by name, for escalation steps that pick one with adapter: (see ModelPath), e.g.
    #   config.adapters = { local: { type: :openai_compatible, base_url: "http://localhost:11434/v1" }, claude: :claude_code }
    # Each value is anything config.adapter takes. A step without adapter: uses config.adapter. Built when assigned.
    attr_reader :adapters

    # Squishling::Testing only: when set, every adapter name resolves to this adapter, so a scripted adapter answers
    # for steps that pick another one.
    attr_accessor :adapter_override

    def initialize
      @adapter = nil
      @adapters = {}.freeze
      @adapter_override = nil
      @detected_adapter = nil
      @adapter_lock = Mutex.new
      @observer = nil
      @default_model = nil
      @default_escalation = nil
      @default_model_path = nil
      @default_provider = nil
      @default_params = {}
      @default_cache = true
      @budget_counts_cache_reads = false
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

    def adapters=(named)
      unless named.nil? || named.is_a?(Hash)
        raise ConfigurationError, "Squishling.configure: adapters must be a Hash of name => adapter, got #{named.class}"
      end

      built = {}
      (named || {}).each do |name, adapter|
        key = adapter_key(name, built)
        built[key] = Adapter.build(adapter, "Squishling.configure adapters[#{key.inspect}]")
      end
      @adapter_lock.synchronize { @adapters = built.freeze }
    end

    # The adapter a step's adapter: names (nil is the default one, see #resolved_adapter). Raises ConfigurationError
    # for a name that isn't configured.
    def adapter_for(name)
      return resolved_adapter if name.nil?

      @adapter_override || named_adapter(name)
    end

    # The adapter configured under a name, whatever Squishling::Testing routes to. Raises ConfigurationError for a name
    # that isn't configured.
    def named_adapter(name)
      named = @adapter_lock.synchronize { @adapters }
      named.fetch(name) do
        known = named.empty? ? "none; set config.adapters" : named.keys.map(&:inspect).join(", ")
        raise ConfigurationError, "unknown adapter #{name.inspect} (configured: #{known})"
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

    # true or false; unlike default_cache=, nil is not accepted.
    def budget_counts_cache_reads=(counts)
      unless [true, false].include?(counts)
        raise ConfigurationError,
          "Squishling.configure: budget_counts_cache_reads must be true or false, got #{counts.inspect}"
      end

      @budget_counts_cache_reads = counts
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

    private

    # An adapters: name as a Symbol; a blank or non-name key, or one already in taken, is a ConfigurationError.
    def adapter_key(name, taken)
      unless (name.is_a?(Symbol) || name.is_a?(String)) && !name.to_s.strip.empty?
        raise ConfigurationError, "Squishling.configure: an adapter name must be a Symbol, got #{name.inspect}"
      end

      key = name.to_sym
      raise ConfigurationError, "Squishling.configure: adapters names #{key.inspect} twice" if taken.key?(key)

      key
    end
  end
end
