# frozen_string_literal: true

module Squishling
  class Error < StandardError; end

  class ConfigurationError < Error; end

  class InvalidOutputError < Error
    attr_reader :errors, :raw

    def initialize(errors:, raw: nil, source: "LLM")
      @errors = errors
      @raw = raw
      super("#{source} output did not match the output schema: #{errors.join('; ')}")
    end
  end
end
