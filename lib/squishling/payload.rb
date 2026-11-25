# frozen_string_literal: true

module Squishling
  # Turns a call's arguments and context into the plain JSON the model is sent. Internal: not part of the public API.
  module Payload
    module_function

    PLAIN_TYPES = [NilClass, TrueClass, FalseClass, String, Symbol, Numeric, Time].freeze

    # label names the call in a ConfigurationError. images collects the Images found, in order: each goes into the
    # JSON as {attached_image: N} (its 1-based number), and the same Image passed twice is attached once.
    def jsonify(value, label, images = [])
      Schema.jsonify(describe(value, label, images))
    end

    # Exceptions are sent as their class and message. Plain JSON would send only the message, and with
    # json/add/exception loaded it would also send the backtrace, which exposes file paths. A Struct, Data, or
    # OpenStruct is sent as its members (to_h) and a Set as its elements, not as Ruby's inspect text. path is the
    # containers being walked: one that contains itself is a ConfigurationError rather than a SystemStackError.
    # Any other object is refused unless it is a JSON primitive, a Time or Date, or defines to_squishling (whose
    # return value is sent in its place): as_json/to_json would send every attribute of, say, an ActiveRecord model.
    def describe(value, label, images, path = [])
      case value
      when Image then { attached_image: attach(value, images) }
      when Exception then { class: exception_class_name(value.class), message: value.message }
      when Array, Set then elements(value, label, images, path)
      when Hash, Struct, Data then members(value, label, images, path)
      else other(value, label, images, path)
      end
    end

    # What isn't a container: an OpenStruct's members, a plain value as it is, or what to_squishling says to send.
    def other(value, label, images, path)
      return members(value, label, images, path) if open_struct?(value)
      return value if plain?(value)

      unless value.respond_to?(:to_squishling)
        raise ConfigurationError,
          "#{label}: #{value.class} can't be sent as JSON, because that could send all of its attributes. " \
          "Pass a plain Hash, or define #{value.class}#to_squishling to return what the model should see"
      end

      within(value, label, path) { |inner| describe(value.to_squishling, label, images, inner) }
    end

    def plain?(value)
      PLAIN_TYPES.any? { |type| value.is_a?(type) } || (defined?(::Date) && value.is_a?(::Date))
    end

    def elements(value, label, images, path)
      within(value, label, path) { |inner| value.map { |item| describe(item, label, images, inner) } }
    end

    def members(value, label, images, path)
      pairs = value.is_a?(Hash) ? value : value.to_h
      unless pairs.is_a?(Hash)
        raise ConfigurationError,
          "#{label}: #{value.class}#to_h must return a Hash to be sent as JSON, got #{pairs.class}"
      end

      within(value, label, path) { |inner| pairs.transform_values { |item| describe(item, label, images, inner) } }
    end

    # OpenStruct is a default gem that Ruby 4.0 stops loading by default, so it can't be named unless it is loaded.
    def open_struct?(value) = defined?(::OpenStruct) && value.is_a?(::OpenStruct) # rubocop:disable Style/OpenStructUse

    def within(container, label, path)
      if path.any? { |ancestor| ancestor.equal?(container) }
        raise ConfigurationError, "#{label}: an argument or context value contains itself, so it can't be sent as JSON"
      end

      yield path + [container]
    end

    # The image's number in the message (1-based), added to images the first time it is seen.
    def attach(image, images)
      index = images.index { |attached| attached.equal?(image) }
      return index + 1 if index

      images << image
      images.size
    end

    # An anonymous error class (Class.new(StandardError)) is named after its closest named ancestor.
    def exception_class_name(klass)
      klass = klass.superclass until klass.name
      klass.name
    end
  end
end
