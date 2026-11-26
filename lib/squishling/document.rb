# frozen_string_literal: true

module Squishling
  # A file that isn't one of the images a model reads as pixels: a PDF the model reads, or a file a sanitizer is to
  # convert (a fax's TIFF, an iPhone's HEIC) before anything is sent. You rarely build one: pass the file (a blob, an
  # upload, a File, a Pathname, a binary String with a known signature) and Squishling makes it. In the JSON input
  # the model sees {"attached_document": N} where it was, and the document goes with the call's first message as a
  # file content part, through any adapter that takes its media type (Adapter::Base#media_types).
  # Anything else the sanitizer leaves in place is refused before any request.
  #
  # Like an Image, its bytes are never logged, inspected, or serialized (see Concealed).
  class Document
    include Concealed

    # What providers read as documents, with the extension the adapters name the file with.
    MEDIA_TYPES = { "application/pdf" => "pdf" }.freeze
    MEDIA_TYPE = %r{\A[\w.+-]{1,60}/[\w.+-]{1,60}\z}

    attr_reader :data, :media_type

    # data: the file's bytes, media_type: its type as "type/subtype" (anything a sniffer or the file's declared type
    # gave). Raises ConfigurationError for empty data or a malformed type.
    def initialize(data:, media_type:)
      unless data.is_a?(String) && !data.empty?
        raise ConfigurationError, "Squishling::Document needs data: (the file's bytes)"
      end
      unless media_type.is_a?(String) && MEDIA_TYPE.match?(media_type)
        raise ConfigurationError, "Squishling::Document media_type must look like \"type/subtype\""
      end

      @data = data.b.freeze
      @media_type = -media_type.downcase
      freeze
    end

    def bytesize
      @data.bytesize
    end

    def url?
      false
    end

    # The bytes as a data: URI.
    def data_uri
      "data:#{@media_type};base64,#{[@data].pack('m0')}"
    end

    # A generic file name for adapters that need one ("document.pdf"). The caller's own name is never kept.
    def filename
      "document.#{MEDIA_TYPES.fetch(@media_type, 'bin')}"
    end

    def inspect
      type = Attachment.known_type?(@media_type) ? @media_type : "an unrecognized type"
      "#<#{self.class.name} #{type}, #{@data.bytesize} bytes>"
    end

    protected

    def state
      [@data, @media_type]
    end
  end
end
