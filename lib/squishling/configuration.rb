# frozen_string_literal: true

module Squishling
  class Configuration
    # Model used by every squishling class that doesn't declare its own.
    # When nil, RubyLLM's own default model is used.
    attr_accessor :default_model

    # Provider for default_model (e.g. :openai). Only needed for models missing from
    # RubyLLM's registry.
    attr_accessor :default_provider

    # How many times to re-ask the LLM when its output fails schema validation.
    attr_accessor :max_retries

    # Optional Logger for routing decisions.
    attr_accessor :logger

    def initialize
      @default_model = nil
      @default_provider = nil
      @max_retries = 1
      @logger = nil
    end
  end
end
