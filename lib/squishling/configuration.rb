# frozen_string_literal: true

module Squishling
  class Configuration
    # Model used by every squishling class that doesn't declare its own (a single attempt).
    # When neither this nor default_escalation is set, RubyLLM's own default model is used.
    attr_reader :default_model

    # Models tried in order by every squishling class that doesn't declare its own, e.g.
    #   [{ model: "claude-haiku-4-5", attempts: 2 }, "claude-sonnet-5-5", "claude-opus-5-5"]
    # See ModelPath. default_model and default_escalation set the same thing: assigning one clears the other.
    attr_reader :default_escalation

    # The validated default_model or default_escalation steps (nil when neither is set).
    attr_reader :default_model_path

    # Provider for default_model/default_escalation steps that don't name their own (e.g. :openai). Only
    # needed for models missing from RubyLLM's registry.
    attr_accessor :default_provider

    # Generation params applied to every call, overridable per class and per method.
    # :temperature and :thinking ({ effort:, budget: }) map to RubyLLM's with_temperature and
    # with_thinking; any other key (top_p, max_tokens, seed, ...) is passed to the provider as-is.
    attr_reader :default_params

    # Optional Logger for routing and escalation decisions.
    attr_accessor :logger

    # Optional callable run after every LLM attempt with the raw output (see Squawk), e.g.
    #   ->(output:, metadata:, error:) { Tracer.record(output, metadata, error) }
    attr_reader :squawk

    def initialize
      @default_model = nil
      @default_escalation = nil
      @default_model_path = nil
      @default_provider = nil
      @default_params = {}
      @logger = nil
      @squawk = nil
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

    def squawk=(hook)
      @squawk = Squawk.validate(hook, "Squishling.configure")
    end

    def default_params=(params)
      @default_params = Params.normalize(params, "default_params")
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
