# frozen_string_literal: true

module Squishling
  # Builds Data classes from a JSON Schema so both the LLM and deterministic paths return
  # the same typed object.
  module Result
    # Property names a generated class can't take: a Data member of the same name replaces the method, which the
    # result (or Squishling) needs. result_spec.rb probes every Object, Kernel, and Data method, so a method a newer
    # Ruby adds can't slip through unreserved.
    RESERVED_NAMES = %i[
      squished? squishling_squished []
      class is_a? kind_of? inspect to_s to_h hash == eql? members deconstruct_keys with dup
      send public_send
      __send__ object_id __id__
      initialize initialize_copy initialize_dup initialize_clone respond_to_missing?
    ].freeze

    # Mixed into every generated result class.
    module Instance
      def initialize(squishling_squished: false, **attrs)
        @squished = squishling_squished
        super(**attrs)
      end

      # True when this result came from the LLM rather than Ruby code.
      def squished?
        @squished
      end

      def [](key)
        members.include?(key.to_sym) ? public_send(key.to_sym) : nil
      end

      def to_h
        super.transform_values { |value| Result.deep_to_h(value) }
      end
    end

    module ClassMethods
      def from_h(hash, squished: false)
        hash = hash.transform_keys(&:to_sym)
        attrs = members.to_h { |member| [member, @squishling_fields[member].call(hash[member], squished)] }
        new(squishling_squished: squished, **attrs)
      end
    end

    class << self
      def build(json_schema)
        Builder.new(json_schema).class_for(json_schema)
      end

      def deep_to_h(value)
        case value
        when Instance then value.to_h
        when Array then value.map { |item| deep_to_h(item) }
        else value
        end
      end
    end

    # Resolves $refs and builds (memoized, so recursive schemas work) one Data class per object schema.
    class Builder
      IDENTITY = ->(value, _squished) { value.is_a?(Hash) ? value.transform_keys(&:to_sym) : value }

      def initialize(root)
        @root = root
        @classes = {}.compare_by_identity
      end

      # Returns a Data class, or nil when the schema isn't an object with properties.
      def class_for(schema)
        schema = resolve(schema)
        return nil unless schema.is_a?(Hash) && schema["properties"].is_a?(Hash)

        return @classes[schema] if @classes.key?(schema)

        require_object_type!(schema)
        klass = @classes[schema] = define_class(schema)
        # Memoized first so recursive schemas stop; typing the fields builds nested classes now, so a bad
        # property name in any object the result types (nested, array items, resolved $refs) raises at schema build.
        klass.instance_variable_set(:@squishling_fields, fields_for(schema))
        klass
      end

      private

      # `properties` alone constrains objects only, so a schema without `type: "object"` accepts a String or Array
      # that would then sit in the typed result where a nested result is expected. A raw Hash schema must say so.
      def require_object_type!(schema)
        type = schema["type"]
        return if type == "object" || (type.is_a?(Array) && type.include?("object"))

        raise ConfigurationError,
          "output_schema has a schema with `properties` but no `type: \"object\"`, so a non-object value would " \
          "pass validation and end up in the typed result. Add `type: \"object\"` to it " \
          "(a union such as [\"object\", \"null\"] is also fine)"
      end

      def fields_for(schema)
        schema["properties"].to_h { |key, property| [key.to_sym, converter_for(property)] }
      end

      def define_class(schema)
        klass = Data.define(*property_names(schema))
        klass.include(Instance)
        klass.extend(ClassMethods)
        klass
      end

      def property_names(schema)
        names = schema["properties"].keys.map(&:to_sym)
        clashes = names & RESERVED_NAMES
        return names if clashes.empty?

        raise ConfigurationError,
          "output_schema property names clash with methods the result needs: #{clashes.join(', ')}. " \
          "Rename the field(s) (e.g. `class` to `ticket_class`)"
      end

      def converter_for(property)
        property = resolve(property)
        return IDENTITY unless property.is_a?(Hash)

        # `optional` (anyOf [schema, null]) is typed as its schema; nil passes through every converter.
        if (branch = nullable_branch(property))
          converter_for(branch)
        elsif (klass = class_for(property))
          ->(value, squished) { value.is_a?(Hash) ? klass.from_h(value, squished:) : value }
        elsif property["items"]
          item = converter_for(property["items"])
          ->(value, squished) { value.is_a?(Array) ? value.map { |v| item.call(v, squished) } : value }
        else
          IDENTITY
        end
      end

      # The single non-null branch of an anyOf/oneOf. Unions with several non-null branches are
      # ambiguous, so their values are left untyped.
      def nullable_branch(property)
        union = property["anyOf"] || property["oneOf"]
        return unless union.is_a?(Array)

        branches = union.reject { |branch| resolve(branch).is_a?(Hash) && resolve(branch)["type"] == "null" }
        branches.first if branches.size == 1
      end

      def resolve(schema)
        return schema unless schema.is_a?(Hash) && schema["$ref"].is_a?(String)
        return schema unless schema["$ref"].start_with?("#/")

        path = schema["$ref"].delete_prefix("#/").split("/")
        @root.dig(*path) || schema
      end
    end
  end
end
