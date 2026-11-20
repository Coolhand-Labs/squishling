# frozen_string_literal: true

module Squishling
  # Turns a call's arguments and context into the plain JSON the model is sent. Internal: not part of the public API.
  module Payload
    module_function

    # label names the call in a ConfigurationError. images collects the Images found, in order: each goes into the
    # JSON as {attached_image: N} (its 1-based number), and the same Image passed twice is attached once.
    def jsonify(value, label, images = [])
      Schema.jsonify(describe(value, label, images))
    end

    # Exceptions are sent as their class and message. Plain JSON would send only the message, and with
    # json/add/exception loaded it would also send the backtrace, which exposes file paths. A Struct, Data, or
    # OpenStruct is sent as its members (to_h) and a Set as its elements, not as Ruby's inspect text. path is the
    # containers being walked: one that contains itself is a ConfigurationError rather than a SystemStackError.
    def describe(value, label, images, path = [])
      case value
      when Image then { attached_image: attach(value, images) }
      when Exception then { class: exception_class_name(value.class), message: value.message }
      when Array, Set then within(value, label, path) { |inner| value.map { |item| describe(item, label, images, inner) } }
      when Hash, Struct, Data then members(value, label, images, path)
      else open_struct?(value) ? members(value, label, images, path) : value
      end
    end

    def members(value, label, images, path)
      pairs = value.is_a?(Hash) ? value : value.to_h
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
