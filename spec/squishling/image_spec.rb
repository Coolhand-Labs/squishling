# frozen_string_literal: true

require "tmpdir"

RSpec.describe Squishling::Image do
  let(:png) { "\x89PNG\r\n\x1A\n#{'x' * 20}".b }
  let(:jpeg) { "\xFF\xD8\xFF\xE0#{'x' * 20}".b }

  describe "from bytes" do
    it "reads the media type from the bytes" do
      expect(described_class.new(data: png).media_type).to eq("image/png")
      expect(described_class.new(data: jpeg).media_type).to eq("image/jpeg")
      expect(described_class.new(data: "GIF89a#{'x' * 10}").media_type).to eq("image/gif")
      expect(described_class.new(data: "RIFF\x00\x00\x00\x00WEBPVP8 ").media_type).to eq("image/webp")
    end

    it "takes the media type it's given" do
      expect(described_class.new(data: "bytes", media_type: "image/jpeg").media_type).to eq("image/jpeg")
    end

    it "refuses a media type it can't send, or one it can't read from the bytes" do
      expect { described_class.new(data: png, media_type: "image/tiff") }
        .to raise_error(Squishling::ConfigurationError, %r{must be one of image/png.*got "image/tiff"})
      expect { described_class.new(data: "plain text") }
        .to raise_error(Squishling::ConfigurationError, /couldn't be read from the bytes/)
    end

    it "refuses no bytes, or bytes and a URL together" do
      expect { described_class.new(data: "") }.to raise_error(Squishling::ConfigurationError, /needs data:/)
      expect { described_class.new }.to raise_error(Squishling::ConfigurationError, /needs data:/)
      expect { described_class.new(data: png, url: "https://example.com/a.png") }
        .to raise_error(Squishling::ConfigurationError, /not both/)
    end

    it "is a data: URI with a file name for adapters that need one" do
      image = described_class.new(data: png)

      expect(image.data_uri).to eq("data:image/png;base64,#{[png].pack('m0')}")
      expect(image.filename).to eq("image.png")
      expect(image.bytesize).to eq(png.bytesize)
      expect(image).not_to be_url
    end
  end

  describe ".from_path" do
    it "reads the file, the media type from its bytes or else its extension" do
      Dir.mktmpdir do |dir|
        File.binwrite(File.join(dir, "receipt.bin"), png)
        File.binwrite(File.join(dir, "receipt.jpeg"), "not a known header")

        expect(described_class.from_path(File.join(dir, "receipt.bin"))).to eq(described_class.new(data: png))
        expect(described_class.from_path(File.join(dir, "receipt.jpeg")).media_type).to eq("image/jpeg")
      end
    end
  end

  describe ".from_url" do
    it "keeps the URL for the provider to fetch" do
      image = described_class.from_url("https://example.com/r.png?sig=1", detail: :high)

      expect(image).to have_attributes(url?: true, url: "https://example.com/r.png?sig=1", detail: :high, data: nil,
        data_uri: nil, filename: nil, media_type: nil)
    end

    it "refuses anything but an http or https URL, and a media type" do
      ["file:///etc/passwd", "ftp://example.com/a.png", "not-a-url", "https://example.com/a b.png"].each do |url|
        expect { described_class.from_url(url) }.to raise_error(Squishling::ConfigurationError, /http or https/)
      end
      expect { described_class.new(url: "https://example.com/a.png", media_type: "image/png") }
        .to raise_error(Squishling::ConfigurationError, /takes no media_type/)
    end

    it "keeps a refused URL out of the error" do
      expect { described_class.from_url("https://example.com/a b.png?token=s3cret") }
        .to raise_error(Squishling::ConfigurationError) { |error| expect(error.message).not_to include("s3cret") }
    end
  end

  it "takes :low or :high detail, as a Symbol or a String" do
    expect(described_class.new(data: png, detail: "low").detail).to eq(:low)
    expect { described_class.new(data: png, detail: :ultra) }
      .to raise_error(Squishling::ConfigurationError, /detail: must be :low or :high/)
  end

  describe "keeping its content out of logs" do
    it "refuses Marshal and dumps YAML as the description" do
      image = described_class.new(data: png)

      expect { Marshal.dump(image) }.to raise_error(TypeError, /can't be dumped/)
      expect(image.to_yaml).to include("Squishling::Image image/png")
      expect(image.to_yaml).not_to include("binary")
    end

    it "describes bytes by media type and size" do
      image = described_class.new(data: png, detail: :low)

      expect(image.inspect).to eq("#<Squishling::Image image/png, #{png.bytesize} bytes, detail: low>")
      expect(image.to_s).to eq(image.inspect)
    end

    it "describes a URL without its credentials, query, or fragment" do
      image = described_class.from_url("https://user:secret@example.com:8443/r.png?X-Amz-Signature=abc#frag")

      expect(image.inspect).to eq("#<Squishling::Image https://example.com:8443/r.png>")
    end

    it "serializes as its description, never its bytes" do
      image = described_class.new(data: png)

      expect(image.as_json).to eq(image.inspect)
      expect(JSON.generate({ image: })).to eq(JSON.generate({ image: image.inspect }))
    end
  end

  it "keeps its media type when the String it was given is changed" do
    given = +"image/png"
    image = described_class.new(data: png, media_type: given)
    given << "x"

    expect(image.media_type).to eq("image/png")
    expect(image.media_type).to be_frozen
  end

  it "is frozen and compares by content" do
    image = described_class.new(data: png.dup)

    expect(image).to be_frozen
    expect(image.data).to be_frozen
    expect(image).to eq(described_class.new(data: png))
    expect(image.hash).to eq(described_class.new(data: png).hash)
    expect(image).not_to eq(described_class.new(data: png, detail: :high))
  end
end
