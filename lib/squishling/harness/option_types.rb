# frozen_string_literal: true

module Squishling
  class Harness
    # The types a harness option can declare (see Base.option). Each checks a given value and returns it
    # normalized, or raises ConfigurationError, so a bad option fails before any request is made.
    #   :step         a model name or a step Hash (model:, provider:, params:, attempts:, forward_rejected:)
    #   :proc, :string, :symbol, :integer, :boolean
    # A harness with a shape of its own declares the type as a callable instead, which gets the value, the
    # declaration site, and the option's name, and returns the normalized value (or raises ConfigurationError).
    module OptionTypes
      TYPES = %i[step proc string symbol integer boolean].freeze

      module_function

      # Whether type is one a harness can declare: a built-in one above, or a callable that takes the value, the
      # label, and the name.
      def type?(type)
        TYPES.include?(type) || (type.respond_to?(:call) && takes_three?(type))
      end

      # Whether the callable can be called with three positional arguments. One without a parameter list
      # (an object with its own call) is trusted.
      def takes_three?(callable)
        return true if callable.is_a?(Proc) && !callable.lambda? # a proc drops the arguments it doesn't name

        method = callable.is_a?(Proc) || callable.is_a?(Method) ? callable : callable.method(:call)
        parameters = method.parameters.map(&:first)
        return false if parameters.include?(:keyreq)
        return true if parameters.include?(:rest)

        3.between?(parameters.count(:req), parameters.count(:req) + parameters.count(:opt))
      end

      # The value as the type's normalized form. label is the declaration site, name the option.
      def check(type, value, label, name)
        return deep_freeze(type.call(value, label, name)) if type.respond_to?(:call)

        send(:"check_#{type}", value, "#{label} #{name}", "#{label}: #{name}:")
      end

      def check_step(value, label, _where)
        step = ModelPath.normalize_step(value, label)
        ModelPath.single_step!(step, "#{label}: a harness step")
        deep_freeze(step)
      end

      def check_proc(value, _label, where)
        check_kind(value, Proc, "a Proc", where)
      end

      def check_string(value, _label, where)
        return value.dup.freeze if value.is_a?(String)

        raise ConfigurationError, "#{where} must be a String, got #{value.class}"
      end

      def check_symbol(value, _label, where)
        return value.to_sym if value.is_a?(Symbol) || value.is_a?(String)

        raise ConfigurationError, "#{where} must be a Symbol, got #{value.class}"
      end

      def check_integer(value, _label, where)
        check_kind(value, Integer, "an Integer", where)
      end

      def check_boolean(value, _label, where)
        return value if [true, false].include?(value)

        raise ConfigurationError, "#{where} must be true or false, got #{value.inspect}"
      end

      # The value itself when it is a kind, else a ConfigurationError saying what was expected.
      def check_kind(value, kind, description, where)
        return value if value.is_a?(kind)

        raise ConfigurationError, "#{where} must be #{description}, got #{value.class}"
      end

      # A frozen copy: normalized steps are shared by every call that uses the declaration, so none can change
      # one, and the caller's own objects stay as they were.
      def deep_freeze(value)
        case value
        when Hash then value.to_h { |key, item| [key, deep_freeze(item)] }.freeze
        when Array then value.map { |item| deep_freeze(item) }.freeze
        when String then value.dup.freeze
        else value
        end
      end
    end
  end
end
