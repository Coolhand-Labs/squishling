# frozen_string_literal: true

module Squishling
  module Payload
    # The first step of building a payload: reads the files in a value and turns what JSON can't carry into plain
    # data. A file becomes an Image, a Document, or (a text file) a String; Exceptions are sent as their class and
    # message (plain JSON would send only the message, and with json/add/exception loaded it would also send the
    # backtrace, which exposes file paths); a Struct, Data, or OpenStruct is sent as its members (to_h) and a Set as
    # its elements, not as Ruby's inspect text. A container that contains itself is a ConfigurationError rather than a
    # SystemStackError. Files are read as they are found, so max_files is checked as the count grows: the call is
    # refused once the count passes the limit, though the file (or collection) that crosses it has been read by then.
    class Normalizer
      # JSON's own limit on nesting (JSON.generate raises past it), so a deeper input is refused here, before a walk
      # that could overflow the stack, instead of there.
      MAX_DEPTH = 100

      PLAIN_TYPES = [Symbol, Numeric, Time].freeze

      def initialize(label)
        @label = label
        @reads = 0
      end

      # Starts the count of files read against max_files again, for the files a sanitizer returns: each pass is held to
      # the limit on its own (the serializer checks the number of files the call sends in the end).
      def restart_count
        @reads = 0
      end

      # containers are the ones being walked, to catch one that contains itself. path is where value is, for an error.
      # A value is walked by what it says first: a class that defines to_squishling is sent as what that returns, so it
      # holds for a Struct, Data, Exception, Hash, Array, or Set subclass too (the way to leave a field out of a
      # Struct). Then by its type.
      def call(value, containers = [], path = nil)
        raise too_deep(path) if containers.size > MAX_DEPTH

        case value
        when Image, Document then value
        when String then text(value, path)
        else squishling?(value) ? squishling(value, containers, path) : by_type(value, containers, path)
        end
      end

      private

      # Whether the class says what to send. A Hash, Struct, Data, exception, or Set is asked for a real definition
      # (on its class or extended onto it), not respond_to?: some, such as ActiveSupport::OrderedOptions, answer true
      # for every name and would send nil for the whole value.
      def squishling?(value)
        case value
        when Hash, Struct, Data, Set, Array, Exception
          value.class.method_defined?(:to_squishling) || value.singleton_class.method_defined?(:to_squishling)
        else value.respond_to?(:to_squishling)
        end
      end

      def by_type(value, containers, path)
        case value
        when Exception then error(value, path)
        when Array, Set then elements(value, containers, path)
        when Hash, Struct, Data then members(value, containers, path)
        else other(value, containers, path)
        end
      end

      def too_deep(path)
        InputRejectedError.single(Payload::TOO_DEEP, label: @label, path:)
      end

      # A String is copied (as UTF-8, which is what is sent), so a sanitizer that changes it in place never changes the
      # caller's own. A binary one may turn out to be a file (see Attachment.string); text isn't counted as one.
      def text(value, path)
        node = located(path) { Attachment.string(value, @label) }
        return utf8(value, path) if node.equal?(value)

        count(node, path) unless node.is_a?(String)
        node
      end

      # An Exception is sent as its class and message, the message as any String is.
      def error(value, path)
        { "class" => exception_class_name(value.class),
          "message" => text(value.message.to_s, Payload.join(path, "message")) }
      end

      def utf8(value, path)
        text = value.encoding == Encoding::UTF_8 ? value.dup : value.encode(Encoding::UTF_8)
        text.valid_encoding? ? text : raise(unconvertible(path))
      rescue EncodingError
        raise unconvertible(path), cause: nil
      end

      def unconvertible(path)
        InputRejectedError.single("a String can't be converted to UTF-8", label: @label, path:)
      end

      # What isn't a String, Exception, or container (see #by_type), in this order, so the most explicit word about an
      # object wins (to_squishling was already honored in #call): an OpenStruct's members; a file (see Attachment),
      # which is read; and last the plain data it serializes to, so a sanitizer is offered what is sent (a model's
      # attributes, not the model). A file is recognized by the methods it answers, which is only a guess, and an
      # OpenStruct whose members happen to be named download or content_type is data, not a file.
      def other(value, containers, path)
        return members(value, containers, path) if open_struct?(value)

        node = located(path) { Attachment.read(value, @label) }
        return plain(value, containers, path) if Attachment::NOT_A_FILE.equal?(node)

        count(node, path)
        node
      end

      # What to_squishling returns is sent in its place, converted like any argument and cycle-guarded like any
      # container: as_json/to_json would send every attribute of, say, an ActiveRecord model.
      def squishling(value, containers, path)
        within(value, containers) { |inner| call(value.to_squishling, inner, path) }
      end

      # Anything that isn't a JSON primitive, a Time, Date or URI is refused (it reached here without a to_squishling).
      def plain(value, containers, path)
        return value if scalar?(value)

        unless plain_type?(value)
          raise ConfigurationError,
            "#{@label}: #{value.class} can't be sent as JSON, because that could send all of its attributes. " \
            "Pass a plain Hash, or define #{value.class}#to_squishling to return what the model should see"
        end

        data = Schema.jsonify(value)
        data.is_a?(Hash) || data.is_a?(Array) ? call(data, containers, path) : data
      rescue JSON::JSONError => e
        raise InputRejectedError.single(Payload.unrepresentable(e), label: @label, path:), cause: nil
      end

      def plain_type?(value)
        PLAIN_TYPES.any? { |type| value.is_a?(type) } ||
          (defined?(::Date) && value.is_a?(::Date)) || value.is_a?(URI::Generic)
      end

      def scalar?(value)
        value.nil? || value == true || value == false ||
          (value.is_a?(Numeric) && (!value.is_a?(Float) || value.finite?))
      end

      # Gives a refusal from reading a file the path of the input it was for.
      def located(path)
        yield
      rescue InputRejectedError => e
        raise unless path && e.rejections.all? { |rejection| rejection.path.nil? }

        raise InputRejectedError.new(e.rejections.map { |rejection| rejection.with(path:) }, label: @label),
          cause: nil
      end

      def count(node, path)
        @reads += node.is_a?(Array) ? node.size : 1 unless node.nil?
        max = Squishling.config.max_files
        return unless max && @reads > max

        raise InputRejectedError.single("#{@reads} files is over max_files (#{max})", label: @label, path:)
      end

      def elements(value, containers, path)
        within(value, containers) do |inner|
          value.each_with_index.map { |item, index| call(item, inner, "#{path}[#{index}]") }
        end
      end

      def members(value, containers, path)
        pairs = value.is_a?(Hash) ? value : value.to_h
        unless pairs.is_a?(Hash)
          raise ConfigurationError,
            "#{@label}: #{value.class}#to_h must return a Hash to be sent as JSON, got #{pairs.class}"
        end

        within(value, containers) do |inner|
          pairs.each_with_object({}) do |(key, item), members|
            name = key.to_s
            raise duplicate_key(path) if members.key?(name)

            members[name] = call(item, inner, Payload.join(path, key))
          end
        end
      end

      # JSON keys are Strings, so a Symbol and a String of the same name would be one key.
      def duplicate_key(path)
        InputRejectedError.single("two keys are the same once sent as JSON (such as a String and a Symbol)",
          label: @label, path:)
      end

      # OpenStruct is a default gem that Ruby 4.0 stops loading by default, so it can't be named unless it is loaded.
      def open_struct?(value)
        defined?(::OpenStruct) && value.is_a?(::OpenStruct) # rubocop:disable Style/OpenStructUse
      end

      def within(container, containers)
        if containers.any? { |ancestor| ancestor.equal?(container) }
          raise ConfigurationError,
            "#{@label}: an argument or context value contains itself, so it can't be sent as JSON"
        end

        yield containers + [container]
      end

      # An anonymous error class (Class.new(StandardError)) is named after its closest named ancestor.
      def exception_class_name(klass)
        klass = klass.superclass until klass.name
        klass.name
      end
    end
  end
end
