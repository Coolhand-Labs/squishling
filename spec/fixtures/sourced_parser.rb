# frozen_string_literal: true

# Fixture for append_instructions source rendering and squish! (see spec/squishling/*_spec.rb).
class SourcedParser
  include Squishling

  instructions "Parse the record."
  append_instructions "The Ruby parser for well-formed records:", self
  output_schema { string :name }

  def call(record:)
    name = record.split(",").fetch(0) { raise ArgumentError, "empty record" }
    result(name:)
  rescue ArgumentError => e
    squish!(append_instructions: "The Ruby parser failed on this record.", context: { parse_error: e })
  end

  def self.build = new
end

module SourcedHelpers
  class Normalizer
    def self.clean(text)
      text.strip
    end
  end
end

SourcedConstant = Class.new do
  def call = :constant
end

# A named class with a method defined from inside an unrelated Module.new block.
class SourcedTarget; end

SourcedMixin = Module.new do
  SourcedTarget.define_method(:borrowed) { :borrowed }
end

module Billing
  class Client
    def charge = :charged
  end
end

# A monkeypatch of Billing::Client from inside an unrelated class with the same short name.
module Vendor
  class Client
    API_KEY = "sk-live-secret"

    Billing::Client.class_eval do
      def refund = :refunded
    end
  end
end

class EncodedParser # parses “smart quotes”
  def call = :encoded
end
