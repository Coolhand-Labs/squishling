# frozen_string_literal: true

require "pathname"
require "uri"

module Squishling
  # Recognizes the files a caller passes to a squished method and reads them, so the caller never builds an Image or
  # a Document: an ActiveStorage attachment or blob (#download, #content_type, #byte_size), an upload (#tempfile,
  # #content_type, #original_filename), a File, Tempfile, StringIO or other IO, a Pathname, an http(s) URI whose path
  # ends in an image extension, and a binary String that starts with a known file signature (what #download,
  # File.binread, and a webhook body return). Internal: not part of the public API. A text String is never a file, and
  # one that names a path would let input choose which file leaves the process.
  #
  # What a file becomes depends on what it is, found from its bytes, then its declared type, then its name's
  # extension: an Image (PNG, JPEG, GIF, WebP), text (HL7, FHIR JSON, CSV, XML: a String, so a sanitizer treats it like
  # any other), or a Document (a PDF, and any other type, such as a fax's TIFF, which a sanitizer may convert; one it
  # leaves is refused before any request). Only the LLM path reads: the Ruby path gets what was passed, as it was.
  module Attachment
    module_function

    # What #read returns for a value that isn't a file.
    NOT_A_FILE = Object.new.freeze

    # Each kind of file, in the order they are tried: the predicate that recognizes it and the reader that makes
    # nodes of it (see the methods below).
    READERS = [
      %i[slot? read_slot], %i[collection? read_many], %i[stored? stored], %i[upload? upload], %i[path? from_path],
      %i[stream? from_io], %i[image_url? from_url]
    ].freeze
    BLOB_SURFACE = %i[download content_type byte_size].freeze
    UPLOAD_SURFACE = %i[tempfile content_type original_filename].freeze
    # Values that are never files, passed over without asking what they respond to (a String is checked apart).
    PLAIN = [String, Numeric, Symbol, NilClass, TrueClass, FalseClass].freeze
    # File signatures: the bytes a type starts with. HEIC and its relatives name a brand after "ftyp" at byte 4.
    SIGNATURES = { "%PDF-".b => "application/pdf", "II*\x00".b => "image/tiff", "MM\x00*".b => "image/tiff" }.freeze
    HEIC_BRANDS = %w[heic heix hevc hevx heim heis mif1 msf1].freeze
    EXTENSIONS = Image::EXTENSIONS.merge(
      ".pdf" => "application/pdf", ".tif" => "image/tiff", ".tiff" => "image/tiff", ".heic" => "image/heic",
      ".heif" => "image/heic", ".json" => "application/json", ".xml" => "application/xml",
      ".ndjson" => "application/x-ndjson", ".csv" => "text/csv", ".tsv" => "text/tab-separated-values",
      ".txt" => "text/plain", ".hl7" => "application/hl7-v2", ".md" => "text/markdown"
    ).freeze
    TEXT_TYPES = %w[application/json application/xml application/x-ndjson application/hl7-v2 application/edi-hl7v2
                    application/yaml].freeze
    GENERIC_TYPES = %w[application/octet-stream binary/octet-stream application/x-binary].freeze
    private_constant :READERS, :BLOB_SURFACE, :UPLOAD_SURFACE, :PLAIN, :SIGNATURES, :HEIC_BRANDS, :EXTENSIONS,
      :TEXT_TYPES, :GENERIC_TYPES

    # The media type the bytes start with (an image, a PDF, a TIFF, a HEIC), or nil.
    def sniff(data)
      head = data.byteslice(0, 12).b
      signature = SIGNATURES.find { |bytes, _| head.start_with?(bytes) }
      return signature.last if signature
      return "image/heic" if head.byteslice(4, 4) == "ftyp" && HEIC_BRANDS.include?(head.byteslice(8, 4))

      Image.sniff(data)
    end

    # A node for a value that is a file: an Image, a Document, a String (a text file), an Array of them (a collection
    # of attachments), nil (an attachment slot with nothing in it), or NOT_A_FILE (including a slot or collection that
    # holds something other than files). label names the call in an InputRejectedError, raised for a file that is
    # empty, too large (see max_file_bytes, checked before it is read where its size is known), or unreadable. The
    # message never carries a path or a name.
    def read(value, label)
      return NOT_A_FILE if PLAIN.any? { |plain| value.is_a?(plain) }

      reader = reader_for(value)
      reader ? send(reader, value, label) : NOT_A_FILE
    end

    # A String as a node: a binary one (what #download and File.binread return) that starts with a known file
    # signature is that file, and one that is really UTF-8 text is that text; a binary one that is neither is refused,
    # since it can't be sent as JSON. Any other String is itself.
    def string(value, label)
      return value unless value.encoding == Encoding::BINARY
      return build(value, nil, nil, label) if sniff(value)

      utf8_text(value) || raise(InputRejectedError.single("a binary String is neither a known file nor text", label:))
    end

    # Whether type is one Squishling knows by name (so it may be quoted in an error): a caller's declared type may not.
    def known_type?(type)
      type == "application/octet-stream" || EXTENSIONS.value?(type) || SIGNATURES.value?(type)
    end

    def reader_for(value)
      READERS.find { |predicate, _| send(predicate, value) }&.last
    end

    # Runs a read of the filesystem or a stream. A failure is refused without the path or the system's message (which
    # carries it), and without a cause, which error trackers would walk to find it.
    def reading(label)
      yield
    rescue SystemCallError, IOError
      raise InputRejectedError.single("a file couldn't be read", label:), cause: nil
    end

    def read_slot(value, label)
      value.attached? ? read(value.attachment, label) : nil
    end

    # ActiveStorage's blob surface (blobs, and attachments, which delegate to theirs). Looser than that would call
    # #download on any application object that happens to have one.
    def stored?(value)
      BLOB_SURFACE.all? { |name| value.respond_to?(name) }
    end

    def upload?(value)
      UPLOAD_SURFACE.all? { |name| value.respond_to?(name) } && !value.tempfile.nil?
    end

    def path?(value)
      value.is_a?(Pathname)
    end

    # Something to read from the start (not a class, a Dir, or a socket or terminal, which would block).
    def stream?(value)
      value.respond_to?(:read) && value.respond_to?(:rewind) && !value.is_a?(Module) && !value.is_a?(Dir) &&
        (!value.is_a?(IO) || value.is_a?(File)) && reads_a_length?(value)
    end

    # Whether #read takes a length (as IO#read does), which is how a stream is read no further than max_file_bytes.
    # Looked up without asking the object (it may define its own #method, or answer #read through method_missing).
    def reads_a_length?(value)
      Kernel.instance_method(:method).bind_call(value, :read).arity != 0
    rescue NameError
      true
    end

    def from_url(value, _label)
      Image.from_url(value.to_s)
    end

    # ActiveStorage::Attached::Many: #attachments, and #attached? (ActiveStorage::Attached::One has #attachment).
    def collection?(value)
      value.respond_to?(:attachments) && value.respond_to?(:attached?)
    end

    def slot?(value)
      value.respond_to?(:attached?) && value.respond_to?(:attachment)
    end

    # A URI is a link far more often than an image, so only one whose path ends in an image extension is sent as one.
    def image_url?(value)
      value.is_a?(URI::HTTP) && Image::EXTENSIONS.key?(File.extname(value.path.to_s).downcase)
    end

    def read_many(value, label)
      files = value.attachments.to_a
      max = Squishling.config.max_files
      if max && files.size > max
        raise InputRejectedError.single("#{files.size} files is over max_files (#{max})", label:)
      end
      return NOT_A_FILE unless files.all? { |file| reader_for(file) }

      files.map { |file| read(file, label) }
    end

    def stored(value, label)
      check_size(value.byte_size, label)
      build(value.download, value.content_type, extension_of(value), label)
    end

    def upload(value, label)
      from_io(value.tempfile, label, value.content_type, value.original_filename)
    end

    def from_path(path, label)
      reading(label) do
        check_size(File.size(path), label)
        build(File.binread(path, read_limit), nil, path.to_s, label)
      end
    end

    def from_io(io, label, declared = nil, name = io.respond_to?(:path) ? io.path : nil)
      reading(label) do
        check_size(size_of(io), label)
        build(read_stream(io), declared, name, label)
      end
    end

    # One byte past the limit, so a file whose size wasn't known (or changed) is still caught without reading it all.
    def read_limit
      max = Squishling.config.max_file_bytes
      max && (max + 1)
    end

    def size_of(io)
      io.size if io.respond_to?(:size)
    end

    # Refuses a file over max_file_bytes before it is read (size is nil when unknown).
    def check_size(size, label)
      max = Squishling.config.max_file_bytes
      return unless max && size && size > max

      raise InputRejectedError.single("a file of #{size} bytes is over max_file_bytes (#{max})", label:)
    end

    # The whole stream, whatever position the caller left it at, and the position put back (even when the read
    # fails) so the Ruby path (or the caller) reads it as before. A stream that can't seek is read from where it is.
    def read_stream(io)
      position = seekable_position(io)
      io.rewind if position
      io.read(read_limit)
    ensure
      io.seek(position) if position
    end

    def seekable_position(io)
      io.pos
    rescue SystemCallError, IOError, NoMethodError
      nil
    end

    def extension_of(value)
      value.respond_to?(:filename) ? value.filename.to_s : nil
    end

    # The node for a file's bytes (see the module's description). The declared type is the caller's, so only one
    # shaped like a media type is used.
    def build(data, declared, name, label)
      data = data.to_s
      raise InputRejectedError.single("a file is empty", label:) if data.empty?

      check_size(data.bytesize, label)
      node_for(data, identify(data, declared, name))
    end

    def identify(data, declared, name)
      sniff(data) || specific_type(declared) || EXTENSIONS[File.extname(name.to_s).downcase]
    end

    # A declared type, unless it is empty, malformed, or one that says nothing (application/octet-stream).
    def specific_type(declared)
      type = declared.to_s.split(";").first.to_s.strip.downcase
      Document::MEDIA_TYPE.match?(type) && !GENERIC_TYPES.include?(type) ? type : nil
    end

    def node_for(data, type)
      return Image.new(data:, media_type: type) if Image::MEDIA_TYPES.key?(type)

      text = utf8_text(data) if type.nil? || text_type?(type)
      text || Document.new(data:, media_type: type || "application/octet-stream")
    end

    def text_type?(type)
      type.start_with?("text/") || type.end_with?("+json", "+xml") || TEXT_TYPES.include?(type)
    end

    # The bytes as a String when they are valid UTF-8 text (no NUL), else nil.
    def utf8_text(data)
      text = data.dup.force_encoding(Encoding::UTF_8)
      text if text.valid_encoding? && !text.include?("\0")
    end
  end
end
