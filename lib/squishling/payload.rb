# frozen_string_literal: true

module Squishling
  # Turns a call's arguments and context into the plain JSON the model is sent, in three steps: normalize (files are
  # read, and a Struct, Set, or Exception becomes plain data), sanitize (the developer's hooks, see Sanitizer), and
  # serialize (each file becomes a placeholder, and what no adapter can send is refused). Internal: not part of the
  # public API.
  module Payload
    SENDABLE = (Image::MEDIA_TYPES.keys + Document::MEDIA_TYPES.keys).freeze
    # A Hash key that may appear in an error's path as it is. Others (a name, an MRN, an email: data) are masked.
    SAFE_KEY = /\A[A-Za-z_][A-Za-z0-9_-]{0,63}\z/

    module_function

    # The JSON body for tree (the call's { arguments:, context: }) and the files it sends, in order: each goes into
    # the JSON as {attached_image: N} or {attached_document: N} (its 1-based number among files of its kind), and the
    # same file passed twice (by content) is attached once. sanitizers run on the receiver, in order. label names the
    # call in an error. Raises InputRejectedError for everything found wrong, before any request.
    def build(tree, label, sanitizers: [], receiver: nil)
      normalizer = Normalizer.new(label)
      node = normalizer.call(tree)
      node = Sanitizer.new(sanitizers, receiver, label, normalizer).call(node) if sanitizers.any?
      files = []
      [json(serialize(node, label, files), label), files]
    end

    # The JSON for one value, with no sanitizing. files collects the files found (see #build).
    def jsonify(value, label, files = [])
      json(serialize(Normalizer.new(label).call(value), label, files), label)
    end

    # Plain JSON data for what serialize returned. A value JSON can't carry (an invalid byte, NaN) is refused without
    # the system's message, which quotes it.
    def json(body, label)
      Schema.jsonify(body)
    rescue JSON::JSONError => e
      raise InputRejectedError.single(unrepresentable(e), label:), cause: nil
    end

    # Why a value can't be JSON, without the value (or the system's message, which quotes it).
    def unrepresentable(error)
      return "an input is nested too deeply to send as JSON" if error.is_a?(JSON::NestingError)

      "an input holds a value JSON can't represent (such as invalid UTF-8 or NaN)"
    end

    def serialize(node, label, files)
      problems = []
      body = serialized(node, files, problems, nil)
      max = Squishling.config.max_files
      if max && files.size > max
        problems << InputRejectedError::Rejection.new(nil, "#{files.size} files is over max_files (#{max})")
      end
      raise InputRejectedError.new(problems, label:) if problems.any?

      body
    end

    def serialized(node, files, problems, path)
      case node
      when Image, Document then { placeholder(node) => attach(node, files, problems, path) }
      when Hash then node.to_h { |key, item| [key, serialized(item, files, problems, join(path, key))] }
      when Array then node.each_with_index.map { |item, index| serialized(item, files, problems, "#{path}[#{index}]") }
      else node
      end
    end

    def placeholder(file)
      file.is_a?(Image) ? :attached_image : :attached_document
    end

    # The file's number among the files of its kind (1-based), added to files the first time it is seen. A file no
    # adapter can send, or one over max_file_bytes, is recorded in problems.
    def attach(file, files, problems, path)
      problems.concat(file_problems(file, path))
      kind = files.select { |attached| attached.instance_of?(file.class) }
      existing = kind.index { |attached| attached.equal?(file) || attached == file }
      return existing + 1 if existing

      files << file
      kind.size + 1
    end

    def file_problems(file, path)
      [unsendable(file), too_large(file)].compact.map { |message| InputRejectedError::Rejection.new(path, message) }
    end

    def unsendable(file)
      return unless file.is_a?(Document) && !Document::MEDIA_TYPES.key?(file.media_type)

      type = Attachment.known_type?(file.media_type) ? file.media_type : "an unrecognized file type"
      "#{type} can't be sent to a model (Squishling sends #{SENDABLE.join(', ')}); convert it with squish_sanitize"
    end

    def too_large(file)
      max = Squishling.config.max_file_bytes
      "#{file.bytesize} bytes is over max_file_bytes (#{max})" if max && file.bytesize && file.bytesize > max
    end

    # path extended by a Hash key, for an error message. A key that isn't a plain identifier is masked, since a Hash
    # keyed by data (an MRN, a name) would put that data in the message.
    def join(path, key)
      return path ? "#{path}.#{key}" : key.to_s if SAFE_KEY.match?(key.to_s)

      "#{path}[key]"
    end
  end
end
