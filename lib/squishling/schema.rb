# frozen_string_literal: true

module Squishling
  # Normalizes the supported output-schema forms into a JSON Schema, validates data against it,
  # and builds typed results.
  class Schema
    CACHE = {}.compare_by_identity
    CACHE_LOCK = Mutex.new

    class << self
      def for(raw)
        CACHE_LOCK.synchronize { CACHE[raw] ||= new(raw) }
      end

      # Deep-convert to plain JSON types (string keys), as the LLM would return them.
      def jsonify(value)
        JSON.parse(JSON.generate(value))
      end
    end

    # The payload handed to RubyLLM's `with_schema`: always strict.
    attr_reader :llm_schema
    # The bare JSON Schema used for validation and result typing.
    attr_reader :json_schema

    def initialize(raw)
      hash = self.class.jsonify(to_hash(raw))
      wrapped = wrapped?(hash)
      body = wrapped ? hash["schema"] : hash

      # Same precedence RubyLLM uses: a top-level strict flag wins over one inside the schema.
      strict = hash.key?("strict") ? hash["strict"] : body["strict"]
      raise ConfigurationError, "Squishling only supports strict output schemas (got strict: false)" if strict == false

      @json_schema = body.except("strict")
      @llm_schema = {
        "name" => hash["name"] || body["title"],
        "description" => hash["description"] || body["description"],
        "schema" => @json_schema,
        "strict" => true
      }.compact
      @validator = JSONSchemer.schema(@json_schema)
    end

    def validate(data)
      @validator.validate(data).map { |error| error["error"] }
    end

    def build(data, squished:)
      result_class ? result_class.from_h(data, squished:) : data
    end

    def result_class
      return @result_class if defined?(@result_class)

      @result_class = Result.build(@json_schema)
    end

    private

    def to_hash(raw)
      case raw
      when Hash then raw
      when Class
        raise ConfigurationError, "#{raw} is not a Schematist::Schema" unless raw <= Schematist::Schema

        raw.new.to_json_schema
      else
        return raw.to_json_schema if raw.respond_to?(:to_json_schema)

        raise ConfigurationError, "Unsupported output_schema: #{raw.inspect}"
      end
    end

    # Some schema objects emit a { name:, description:, schema: {...} } wrapper instead of a bare schema.
    def wrapped?(hash)
      hash["schema"].is_a?(Hash) && !hash.key?("type") && !hash.key?("properties")
    end
  end
end
