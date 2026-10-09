# frozen_string_literal: true

module Squishling
  # Normalizes the supported output-schema forms into a JSON Schema, validates data against it,
  # and builds typed results.
  class Schema
    CACHE = {}.compare_by_identity
    CACHE_LOCK = Mutex.new

    # Conditional keywords (Schematist's `given` and `dependent`) that providers' strict modes don't support.
    # They're validated locally and kept out of the schema sent to the LLM.
    LOCAL_ONLY_KEYWORDS = %w[if then else dependentRequired dependentSchemas].freeze
    # Keywords whose value is a map of names to schemas: the names are data, never keywords to strip.
    SCHEMA_MAPS = %w[properties patternProperties $defs definitions].freeze
    # Keywords whose value is literal data, copied untouched.
    DATA_KEYWORDS = %w[enum const default examples].freeze

    class << self
      def for(raw)
        CACHE_LOCK.synchronize { CACHE[raw] ||= new(raw) }
      end

      # Deep-convert to plain JSON types (string keys), as the LLM would return them.
      def jsonify(value)
        JSON.parse(JSON.generate(value))
      end
    end

    # The payload handed to RubyLLM's `with_schema`: always strict, without LOCAL_ONLY_KEYWORDS.
    attr_reader :llm_schema
    # The full JSON Schema used for validation and result typing.
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
        "schema" => provider_schema(@json_schema),
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

    # A copy of the schema without the conditional keywords. An allOf made only of conditionals (how
    # Schematist emits several `given` blocks) goes too.
    def provider_schema(node)
      case node
      when Array then node.map { |item| provider_schema(item) }
      when Hash
        copy = node.each_with_object({}) do |(key, value), stripped|
          next if LOCAL_ONLY_KEYWORDS.include?(key)

          stripped[key] =
            if DATA_KEYWORDS.include?(key)
              value
            elsif SCHEMA_MAPS.include?(key) && value.is_a?(Hash)
              value.transform_values { |schema| provider_schema(schema) }
            else
              provider_schema(value)
            end
        end
        without_conditional_all_of(copy, node)
      else node
      end
    end

    def without_conditional_all_of(copy, original)
      return copy unless original["allOf"].is_a?(Array)

      kept = copy["allOf"].zip(original["allOf"]).reject { |_, branch| conditional_only?(branch) }.map(&:first)
      kept.empty? ? copy.except("allOf") : copy.merge("allOf" => kept)
    end

    def conditional_only?(branch)
      branch.is_a?(Hash) && branch.any? && (branch.keys - LOCAL_ONLY_KEYWORDS - %w[description $comment]).empty?
    end

    # Some schema objects emit a { name:, description:, schema: {...} } wrapper instead of a bare schema.
    def wrapped?(hash)
      hash["schema"].is_a?(Hash) && !hash.key?("type") && !hash.key?("properties")
    end
  end
end
