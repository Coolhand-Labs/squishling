# frozen_string_literal: true

require "uri"

module Squishling
  # An image sent to the model with a squished call. Pass it as an argument (or inside one, in a Hash or an Array):
  # in the JSON input the model sees {"attached_image": N} where the image was, and the image itself goes with the
  # call's first message as an image content part, through any adapter that takes images (Adapter::Base#images?).
  # The Ruby path gets the Image as it was passed.
  #
  #   Squishling::Image.from_path("receipt.jpg")
  #   Squishling::Image.new(data: blob.download, media_type: "image/png", detail: :high)
  #   Squishling::Image.from_url("https://example.com/receipt.png")
  #
  # The bytes are never logged, inspected, or serialized: #inspect, #to_s, #as_json and #to_json describe the image
  # (media type and size, or a URL without its query), so an image in an error, a log line, or a squawk report
  # carries no content. Images are immutable and compare by content.
  class Image
    include Concealed

    MEDIA_TYPES = { "image/png" => "png", "image/jpeg" => "jpg", "image/gif" => "gif", "image/webp" => "webp" }.freeze
    EXTENSIONS = { ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg", ".gif" => "image/gif",
                   ".webp" => "image/webp" }.freeze
    # How much of the image the provider looks at: :low or :high (nil for the provider's default). Providers without
    # the setting ignore it.
    DETAILS = %i[low high].freeze

    # The bytes, or nil for an image given by URL.
    attr_reader :data
    attr_reader :media_type, :detail, :url

    class << self
      # An image read from a file. The media type comes from the bytes, or the extension when given none.
      def from_path(path, media_type: nil, detail: nil)
        data = File.binread(path)
        new(data:, media_type: media_type || sniff(data) || EXTENSIONS[File.extname(path.to_s).downcase], detail:)
      end

      # An image the provider fetches itself (http or https). Nothing is downloaded here.
      def from_url(url, detail: nil)
        new(url:, detail:)
      end

      # The media type the bytes start with, or nil.
      def sniff(data)
        head = data.byteslice(0, 12).b
        if head.start_with?("\x89PNG\r\n\x1A\n".b) then "image/png"
        elsif head.start_with?("\xFF\xD8\xFF".b) then "image/jpeg"
        elsif head.start_with?("GIF87a", "GIF89a") then "image/gif"
        elsif head.start_with?("RIFF") && head.byteslice(8, 4) == "WEBP" then "image/webp"
        end
      end
    end

    # Exactly one of data: (the image's bytes, with its media_type:, which is read from the bytes when left out) and
    # url: (http or https). Raises ConfigurationError for anything else.
    def initialize(data: nil, media_type: nil, url: nil, detail: nil)
      raise ConfigurationError, "Squishling::Image takes data: or url:, not both" if data && url

      @detail = checked_detail(detail)
      if url
        raise ConfigurationError, "Squishling::Image from a url: takes no media_type:" if media_type

        @url = checked_url(url)
      else
        @data = checked_data(data)
        @media_type = checked_media_type(media_type&.to_s || self.class.sniff(@data))
      end
      freeze
    end

    def url?
      !@url.nil?
    end

    def bytesize
      @data&.bytesize
    end

    # The bytes as a data: URI (nil for an image given by URL).
    def data_uri
      @data && "data:#{@media_type};base64,#{[@data].pack('m0')}"
    end

    # A file name for adapters that need one ("image.png"), or nil for an image given by URL.
    def filename
      @data && "image.#{MEDIA_TYPES.fetch(@media_type)}"
    end

    def inspect
      described = url? ? safe_url : "#{@media_type}, #{@data.bytesize} bytes"
      "#<#{self.class.name} #{described}#{", detail: #{@detail}" if @detail}>"
    end

    protected

    def state
      [@data, @media_type, @url, @detail]
    end

    private

    def checked_data(data)
      unless data.is_a?(String) && !data.empty?
        raise ConfigurationError, "Squishling::Image needs data: (the image's bytes) or url:"
      end

      data.b.freeze
    end

    def checked_media_type(media_type)
      return -media_type if MEDIA_TYPES.key?(media_type)

      problem = media_type ? "got #{media_type.inspect}" : "it couldn't be read from the bytes"
      raise ConfigurationError,
        "Squishling::Image media_type must be one of #{MEDIA_TYPES.keys.join(', ')} (#{problem})"
    end

    def checked_url(url)
      uri = URI.parse(url.to_s)
      return uri.to_s.freeze if %w[http https].include?(uri.scheme&.downcase) && uri.host

      raise ConfigurationError, "Squishling::Image url: must be an http or https URL"
    rescue URI::InvalidURIError
      raise ConfigurationError, "Squishling::Image url: must be an http or https URL"
    end

    def checked_detail(detail)
      return nil if detail.nil?

      detail = detail.to_s.to_sym
      return detail if DETAILS.include?(detail)

      raise ConfigurationError, "Squishling::Image detail: must be #{DETAILS.map(&:inspect).join(' or ')}, or nil"
    end

    # The URL without credentials, query, or fragment: a signed URL's query holds its token.
    def safe_url
      uri = URI.parse(@url)
      "#{uri.scheme}://#{uri.host}#{":#{uri.port}" unless uri.port == uri.default_port}#{uri.path}"
    end
  end
end
