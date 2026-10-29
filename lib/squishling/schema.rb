# frozen_string_literal: true

module Squishling
  # Normalizes the supported output-schema forms into a JSON Schema, validates data against it,
  # and builds typed results.
  class Schema
    # Held weakly by the raw schema (a Schematist class, a Hash), so classes replaced by code reloading can be
    # collected along with their schemas. A Hash compares by content, which yields the same schema.
    CACHE = ObjectSpace::WeakKeyMap.new
    CACHE_LOCK = Mutex.new
    # What building a validator raises for a $ref (or $schema) it can't resolve. json_schemer's default resolver
    # refuses remote URIs, so none is fetched.
    REF_ERRORS = [
      JSONSchemer::UnknownRef, JSONSchemer::InvalidRefResolution, JSONSchemer::InvalidRefPointer, URI::InvalidURIError
    ].freeze

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

    # The payload handed to the adapter (Adapter::Request#schema): always strict, without LOCAL_ONLY_KEYWORDS.
    attr_reader :llm_schema
    # The full JSON Schema used for validation and result typing.
    attr_reader :json_schema
    # The Data class results are built as, or nil when the schema isn't an object with properties.
    attr_reader :result_class

    def initialize(raw)
      hash = self.class.jsonify(to_hash(raw))
      wrapped = wrapped?(hash)
      body = wrapped ? hash["schema"] : hash

      # Same precedence RubyLLM 2.0 uses: a top-level strict flag wins over one inside the schema.
      strict = hash.key?("strict") ? hash["strict"] : body["strict"]
      raise ConfigurationError, "Squishling only supports strict output schemas (got strict: false)" if strict == false

      @json_schema = body.except("strict")
      @llm_schema = {
        "name" => hash["name"] || body["title"],
        "description" => hash["description"] || body["description"],
        "schema" => provider_schema(@json_schema),
        "strict" => true
      }.compact
      @validator = validator_for(@json_schema)
      # Built now so a property name the result can't take fails here, not on the first response.
      @result_class = Result.build(@json_schema)
    end

    def validate(data)
      errors = @validator.validate(data).map { |error| error["error"] }
      # A raw Hash schema can leave out type: "object"; the typed result is built from a Hash, so anything else is
      # invalid output rather than a NoMethodError out of the builder.
      errors.empty? && result_class && !data.is_a?(Hash) ? ["root must be an object"] : errors
    end

    def build(data, squished:)
      result_class ? result_class.from_h(data, squished:) : data
    end

    private

    # The json_schemer validator, with every $ref resolved now, so one that points nowhere (a remote URI, a missing
    # $defs entry) fails at build and in Squishling.verify, not on the first response.
    def validator_for(json_schema)
      validator = JSONSchemer.schema(json_schema)
      resolve_refs!(validator, {}.compare_by_identity)
      validator
    rescue *REF_ERRORS => e
      raise ConfigurationError, "output_schema has a $ref that can't be resolved (#{e.message}); " \
                                "only references within the schema are supported"
    end

    # Walks the parsed schema (json_schemer's Schema#parsed and Keyword#ref_schema) and into each target a $ref
    # resolves to, so a reference inside a subschema kept under any keyword is checked too. seen stops cycles.
    def resolve_refs!(schema, seen)
      return if seen.key?(schema)

      seen[schema] = true
      schema.parsed.each_value do |keyword|
        resolve_refs!(keyword.ref_schema, seen) if keyword.respond_to?(:ref_schema)
        subschemas(keyword.parsed).each { |subschema| resolve_refs!(subschema, seen) }
      end
    end

    # The Schema objects directly under a parsed keyword: itself, in a list, or in a map of names.
    def subschemas(parsed)
      case parsed
      when JSONSchemer::Schema then [parsed]
      when Array then parsed.grep(JSONSchemer::Schema)
      when Hash then parsed.values.grep(JSONSchemer::Schema)
      else []
      end
    end

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
