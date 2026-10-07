# frozen_string_literal: true

module Squishling
  class Configuration
    # Model used by every squishling class that doesn't declare its own.
    # When nil, RubyLLM's own default model is used.
    attr_accessor :default_model

    # Provider for default_model (e.g. :openai). Only needed for models missing from
    # RubyLLM's registry.
    attr_accessor :default_provider

    # Generation params applied to every call, overridable per class and per method.
    # :temperature and :thinking ({ effort:, budget: }) map to RubyLLM's with_temperature and
    # with_thinking; any other key (top_p, max_tokens, seed, ...) is passed to the provider as-is.
    attr_reader :default_params

    # How many times to re-ask the LLM when its output fails schema validation.
    attr_accessor :max_retries

    # Optional Logger for routing decisions.
    attr_accessor :logger

    def initialize
      @default_model = nil
      @default_provider = nil
      @default_params = {}
      @max_retries = 1
      @logger = nil
    end

    def default_params=(params)
      @default_params = Params.normalize(params, "default_params")
    end
  end
end
