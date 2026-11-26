# frozen_string_literal: true

module Squishling
  # Holds a credential (an API key, or the headers that may carry one) so a serializer that walks an object's instance
  # variables can't write it out: to_s, inspect, to_yaml, as_json (so ActiveSupport's instance_values walk too) and
  # to_json all show "[REDACTED]", and Marshal refuses. The value sits in a closure rather than an instance variable;
  # #reveal is the only way to read it, and it is for the code that sends the request. Code running in the process can
  # still call #reveal; this guards against accidental serialization (a logged config, an error tracker, a cache
  # dump), not against a hostile caller.
  class Secret
    REDACTED = "[REDACTED]"

    def initialize(value)
      @reveal = -> { value }
      freeze
    end

    def reveal
      @reveal.call
    end

    def inspect
      REDACTED
    end

    alias_method :to_s, :inspect

    def encode_with(coder)
      coder.scalar = REDACTED
    end

    def as_json(*)
      REDACTED
    end

    def to_json(*)
      REDACTED.to_json
    end

    def marshal_dump
      raise TypeError, "Squishling::Secret can't be dumped: it holds a credential"
    end
  end
  private_constant :Secret
end
