# frozen_string_literal: true

module Squishling
  # What Image and Document share: a value that holds a file's bytes and must never show them. #inspect (each class's
  # own), #to_s, #as_json, #to_json and YAML describe it, and Marshal refuses, so a log line, an error, a squawk report,
  # or a serializer carries no content. Values are immutable and compare by content. Internal: not part of the
  # public API.
  module Concealed
    def to_s = inspect

    # Serializers (Rails' as_json walks instance variables) get the description, never the bytes.
    def as_json(*)
      inspect
    end

    def to_json(*)
      JSON.generate(inspect)
    end

    # YAML gets the description, and Marshal refuses (the way Secret does), so a cache or job payload can't carry bytes.
    def encode_with(coder)
      coder.scalar = inspect
    end

    def marshal_dump
      raise TypeError, "#{self.class.name} can't be dumped: it holds the file's bytes"
    end

    def ==(other)
      other.instance_of?(self.class) && other.state == state
    end
    alias_method :eql?, :==

    def hash
      [self.class, *state].hash
    end

    protected

    def state
      raise NotImplementedError, "#{self.class} must implement #state"
    end
  end
end
