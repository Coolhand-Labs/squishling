# frozen_string_literal: true

module Squishling
  module Testing
    # Replies derived from an output schema, so a test that doesn't care about the content stays valid when the schema
    # changes, and a test of "out of range gets re-asked" doesn't hand-write a bad payload. Replies are Hashes with
    # string keys, as JSON would carry them, and are always checked against the schema before they are returned.
    module Fixtures
      FORMATS = {
        "date-time" => "2024-01-01T00:00:00Z", "date" => "2024-01-01", "time" => "00:00:00Z",
        "email" => "user@example.com", "uri" => "https://example.com", "uuid" => "00000000-0000-4000-8000-000000000000"
      }.freeze
      MAX_DEPTH = 8
      WRONG_VALUES = ["not valid", -1_000_000_007, [], {}, true, nil].freeze

      class << self
        # A reply that satisfies the schema of a squished class's method, a Squishling::Schema, or a schema Hash.
        # overrides replace top-level attributes.
        def valid_reply_for(source, method: :call, **overrides)
          schema = schema_of(source, method)
          reply = Generator.new(schema.json_schema).value
          reply = reply.merge(overrides.transform_keys(&:to_s)) if reply.is_a?(Hash)
          verify!(schema, reply, "valid")
        end

        # A valid reply with one top-level attribute (violating:) broken: out of its enum or range, the wrong type,
        # null, or missing. how: (:enum, :range, :type, :null, :missing) picks the break; by default the first that
        # the schema rejects. Overrides are applied to the valid reply first.
        def invalid_reply_for(source, violating:, how: nil, method: :call, **overrides)
          schema = schema_of(source, method)
          base = valid_reply_for(schema, **overrides)
          key = violating.to_s
          raise SetupError, "the schema has no property #{key.inspect} to violate" unless schema.json_schema.fetch(
            "properties", {}
          ).key?(key)

          candidates = breaks(schema.json_schema, key, how)
          broken = candidates.lazy.map { |value| mutate(base, key, value) }.find { |reply| schema.validate(reply).any? }
          broken or raise SetupError,
            "couldn't find a value of #{key.inspect} that the schema rejects#{" (how: #{how.inspect})" if how}"
        end

        private

        def schema_of(source, method)
          case source
          when Schema then source
          when Class then source.squishling_definition(method).schema or raise SetupError,
            "#{source} has no output_schema"
          else Schema.for(source)
          end
        end

        def verify!(schema, reply, kind)
          errors = schema.validate(reply)
          return reply if errors.empty?

          raise SetupError,
            "couldn't build a #{kind} reply (#{errors.join('; ')}); pass the attributes it needs as overrides"
        end

        def mutate(base, key, value)
          value.equal?(:missing) ? base.except(key) : base.merge(key => value)
        end

        def breaks(json_schema, key, how)
          node = Generator.new(json_schema).node_for(json_schema.fetch("properties").fetch(key))
          all = { enum: enum_breaks(node), range: range_breaks(node), type: WRONG_VALUES.compact, null: [nil],
                  missing: [:missing] }
          return all.fetch(how) { raise ArgumentError, "how: is one of #{all.keys.map(&:inspect).join(', ')}" } if how

          all.values.flatten(1)
        end

        def enum_breaks(node)
          values = node["enum"] ? ["not in the enum"] : []
          node.key?("const") ? values + ["not the const"] : values
        end

        def range_breaks(node)
          bounds = node.slice("minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "minLength", "maxLength",
            "minItems", "maxItems")
          bounds.flat_map { |name, limit| beyond(name, limit) }
        end

        def beyond(name, limit)
          case name
          when "minimum", "exclusiveMinimum" then [limit - 1]
          when "maximum", "exclusiveMaximum" then [limit + 1]
          when "minLength" then ["x" * [limit - 1, 0].max]
          when "maxLength" then ["x" * (limit + 1)]
          when "minItems" then [[nil] * [limit - 1, 0].max]
          when "maxItems" then [[nil] * (limit + 1)]
          end
        end
      end

      # Builds one value that satisfies a JSON schema (see Fixtures).
      class Generator
        def initialize(root)
          @root = root
          @expanding = []
        end

        # The value for a node. A $ref being expanded is remembered, so a recursive schema (a node whose child is
        # the same node or null) ends at the null instead of nesting forever.
        def value(node = @root, depth = 0)
          ref = node["$ref"]
          @expanding.push(ref) if ref
          generate(node_for(node), depth)
        ensure
          @expanding.pop if ref
        end

        # The schema node with a root-relative $ref followed.
        def node_for(node)
          ref = node["$ref"]
          return node unless ref

          path = ref.delete_prefix("#").split("/").reject(&:empty?)
          node.except("$ref").merge(path.reduce(@root) do |memo, part|
            memo.fetch(part.gsub("~1", "/").gsub("~0", "~"))
          end)
        end

        private

        def generate(node, depth)
          return node["const"] if node.key?("const")
          return node["enum"].first if node["enum"]
          return from_branch(node, depth) if node["anyOf"] || node["oneOf"]
          return from_all_of(node, depth) if node["allOf"]

          typed(node, depth)
        end

        def from_branch(node, depth)
          branches = node["anyOf"] || node["oneOf"]
          open = branches.reject { |branch| branch["$ref"] && @expanding.include?(branch["$ref"]) }
          chosen = open.find { |branch| branch["type"] != "null" } || open.first || branches.first
          value(chosen, depth + 1)
        end

        def from_all_of(node, depth)
          parts = node["allOf"].map { |part| value(part, depth + 1) }.grep(Hash)
          parts.reduce({}) { |memo, part| memo.merge(part) }
        end

        def typed(node, depth)
          case primary_type(node)
          when "object" then object(node, depth)
          when "array" then array(node, depth)
          when "string" then string(node)
          when "integer", "number" then number(node)
          when "boolean" then true
          end
        end

        def primary_type(node)
          types = Array(node["type"])
          types.find { |type| type != "null" } || (types.first if types.any?) || inferred_type(node)
        end

        def inferred_type(node)
          return "object" if node["properties"]

          "array" if node["items"]
        end

        def object(node, depth)
          return {} if depth > MAX_DEPTH

          (node["properties"] || {}).transform_values { |property| value(property, depth + 1) }
        end

        def array(node, depth)
          return [] if depth > MAX_DEPTH || !node["items"]

          Array.new(node["minItems"].to_i) { value(node["items"], depth + 1) }
        end

        def string(node)
          text = FORMATS.fetch(node["format"], "example")
          text = text.ljust(node["minLength"], "x") if node["minLength"]
          node["maxLength"] ? text[0, node["maxLength"]] : text
        end

        def number(node)
          number = clamp_up(0, node["minimum"], node["exclusiveMinimum"])
          number = clamp_down(number, node["maximum"], node["exclusiveMaximum"])
          primary_type(node) == "integer" ? number.ceil : number
        end

        def clamp_up(number, minimum, exclusive)
          number = minimum if minimum && number < minimum
          exclusive && number <= exclusive ? exclusive + 1 : number
        end

        def clamp_down(number, maximum, exclusive)
          number = maximum if maximum && number > maximum
          exclusive && number >= exclusive ? exclusive - 1 : number
        end
      end
    end
  end
end
