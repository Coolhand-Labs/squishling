# frozen_string_literal: true

module Squishling
  # Turns a call's arguments and context into the plain JSON the model is sent.
  module Payload
    module_function

    def jsonify(value, label)
      Schema.jsonify(describe(value, label))
    end

    # Exceptions are sent as their class and message. Plain JSON would send only the message, and with
    # json/add/exception loaded it would also send the backtrace, which exposes file paths. A Struct, Data, or
    # OpenStruct is sent as its members (to_h) and a Set as its elements, not as Ruby's inspect text. path is the
    # containers being walked: one that contains itself is a ConfigurationError rather than a SystemStackError.
    def describe(value, label, path = [])
      case value
      when Exception then { class: exception_class_name(value.class), message: value.message }
      when Hash
        within(value, label, path) { |inner| value.transform_values { |item| describe(item, label, inner) } }
      when Array, Set then within(value, label, path) { |inner| value.map { |item| describe(item, label, inner) } }
      else keyed?(value) ? members(value, label, path) : value
      end
    end

    def keyed?(value) = value.is_a?(Struct) || value.is_a?(Data) || open_struct?(value)

    def members(value, label, path)
      within(value, label, path) { |inner| value.to_h.transform_values { |item| describe(item, label, inner) } }
    end

    # OpenStruct is a default gem that Ruby 4.0 stops loading by default, so it can't be named unless it is loaded.
    def open_struct?(value) = defined?(::OpenStruct) && value.is_a?(::OpenStruct) # rubocop:disable Style/OpenStructUse

    def within(container, label, path)
      if path.any? { |ancestor| ancestor.equal?(container) }
        raise ConfigurationError, "#{label}: an argument or context value contains itself, so it can't be sent as JSON"
      end

      yield path + [container]
    end

    # An anonymous error class (Class.new(StandardError)) is named after its closest named ancestor.
    def exception_class_name(klass)
      klass = klass.superclass until klass.name
      klass.name
    end
  end
end
