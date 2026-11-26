# frozen_string_literal: true

require "squishling/testing"
require_relative "../support/sent_request"
require "tempfile"
require "tmpdir"
require "stringio"
require "ruby_llm"

RSpec.describe "Files passed to a squished call" do # rubocop:disable RSpec/DescribeClass
  include Squishling::Testing::RSpec
  include SentRequest

  let(:klass) do
    Class.new do
      include Squishling

      squishling model: "vision"
      purpose "Read the receipt."
      output_schema { integer :total_cents }

      def self.to_s = "ReceiptReader"
    end
  end

  let(:png) { "\x89PNG\r\n\x1A\n#{'x' * 20}".b }
  let(:jpeg) { "\xFF\xD8\xFF\xE0#{'y' * 20}".b }
  let(:answer) { { "total_cents" => 1234 } }
  # Stand-ins for ActiveStorage: a blob, an Attached::One (with or without a file), and an Attached::Many. Plain
  # classes, since a Struct is sent as its members.
  let(:blob_class) do
    Class.new do
      attr_reader :content_type

      def initialize(bytes, content_type)
        @bytes = bytes
        @content_type = content_type
      end

      def download = @bytes
      def byte_size = @bytes.bytesize
    end
  end
  let(:one_class) do
    Class.new do
      attr_reader :attachment

      def initialize(attachment) = @attachment = attachment
      def attached? = !attachment.nil?
      def to_squishling = { attached: attached? }
    end
  end
  let(:many_class) do
    Class.new do
      attr_reader :attachments

      def initialize(attachments) = @attachments = attachments
      def attached? = attachments.any?
      def to_squishling = { attached: attached? }
    end
  end
  let(:upload_class) do
    Class.new do
      attr_reader :tempfile, :content_type, :original_filename

      def initialize(tempfile, content_type, original_filename)
        @tempfile = tempfile
        @content_type = content_type
        @original_filename = original_filename
      end

      def to_squishling = { filename: original_filename }
    end
  end

  def write(name, bytes)
    File.join(@dir, name).tap { |path| File.binwrite(path, bytes) }
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  describe "what is sent" do
    it "sends a File, a Pathname, a StringIO and a Tempfile as images, with their placeholders" do
      Tempfile.create(["scan", ".png"], binmode: true) do |tempfile|
        tempfile.write(png)
        tempfile.flush
        request = sent_request(file: File.open(write("a.jpg", jpeg)), path: Pathname(write("b.png", png)),
          io: StringIO.new("#{jpeg}z"), temp: tempfile)

        expect(request.arguments.values).to eq([1, 2, 3, 2].map { |n| { "attached_image" => n } })
        expect(request.images.map(&:media_type)).to eq(%w[image/jpeg image/png image/jpeg])
      end
    end

    it "leaves a stream where the caller had it" do
      io = StringIO.new(png)
      io.read(3)

      sent_request(io:)

      expect(io.pos).to eq(3)
    end

    it "reads the media type from the bytes before the name or the declared type" do
      blob = blob_class.new(png, "application/octet-stream")

      expect(sent_request(blob:).images.first.media_type).to eq("image/png")
    end

    it "falls back to the declared type, then the extension, when the bytes don't say" do
      declared = blob_class.new("not sniffable", "image/webp")
      named = Pathname(write("scan.gif", "not sniffable"))

      images = sent_request(declared:, named:).images

      expect(images.map(&:media_type)).to eq(%w[image/webp image/gif])
    end

    it "sends an upload, a blob, an attached file and a collection of them" do
      upload = upload_class.new(StringIO.new(png), "image/png", "r.png")
      one = one_class.new(blob_class.new(jpeg, "image/jpeg"))
      many = many_class.new([blob_class.new("#{png}1", "image/png"), blob_class.new("#{png}2", "image/png")])

      request = sent_request(upload:, one:, many:)

      expect(request.arguments["many"]).to eq([{ "attached_image" => 3 }, { "attached_image" => 4 }])
      expect(request.images.size).to eq(4)
    end

    it "sends nothing for an attachment slot with no file" do
      request = sent_request(one: one_class.new(nil), many: many_class.new([]))

      expect(request.arguments).to eq("one" => nil, "many" => [])
      expect(request.images).to be_empty
    end

    it "keeps the order of an Array and sends one copy of a file passed twice" do
      request = sent_request(pages: [blob_class.new(jpeg, nil), blob_class.new(png, nil), blob_class.new(jpeg, nil)])

      expect(request.arguments["pages"]).to eq([1, 2, 1].map { |n| { "attached_image" => n } })
      expect(request.images.map(&:media_type)).to eq(%w[image/jpeg image/png])
    end

    it "sends a URI that ends in an image extension, and leaves other links as text" do
      request = sent_request(photo: URI("https://example.com/r.png?sig=1"), page: URI("https://example.com/r"))

      expect(request.images.map(&:url)).to eq(["https://example.com/r.png?sig=1"])
      expect(request.arguments["page"]).to eq("https://example.com/r")
    end

    it "never reads a String as a file" do
      path = write("a.png", png)
      request = sent_request(path:, text: "GIF89a is a header")

      expect(request.images).to be_empty
      expect(request.arguments).to eq("path" => path, "text" => "GIF89a is a header")
    end
  end

  describe "the Ruby path" do
    it "gets the file as passed and never reads it" do
      seen = nil
      klass.squish_when { |**| false }
      klass.define_method(:call) { |file:, **| (seen = file) && { total_cents: 1 } }
      io = StringIO.new(png)

      klass.call(file: io)

      expect(seen).to equal(io)
      expect(io.pos).to eq(0)
    end
  end

  describe "values that only look like files" do
    it "never calls download on an object with download and content_type but no blob surface" do
      document = Class.new do
        def download = raise("must not be called")
        def content_type = "text/plain"
      end.new

      expect { sent_request(document:) }
        .to raise_error(Squishling::ConfigurationError, /can't be sent as JSON/)
    end

    it "sends a collection or slot of things that aren't files as they were" do
      many = many_class.new([1, 2])
      one = one_class.new(3)

      request = sent_request(many:, one:)

      expect(request.images).to be_empty
      expect(request.arguments.keys).to eq(%w[many one])
    end

    it "leaves a Struct with a download member to be sent as its members" do
      holder = Struct.new(:download, :content_type, :byte_size).new("x", "text/plain", 1)

      expect(sent_request(holder:).arguments["holder"]).to eq("download" => "x", "content_type" => "text/plain",
        "byte_size" => 1)
    end
  end

  describe "a file that can't be read" do
    it "refuses a missing path, a directory and a closed stream without naming them" do
      closed = StringIO.new(png).tap(&:close)

      [Pathname(File.join(@dir, "missing.png")), Pathname(@dir), closed].each do |file|
        expect { sent_request(file:) }
          .to raise_error(Squishling::InputRejectedError, "ReceiptReader#call: arguments.file: a file couldn't be read")
      end
    end

    it "puts a stream back where it was even when it can't be read" do
      io = StringIO.new(png)
      io.read(3)
      allow(io).to receive(:read).and_raise(IOError)

      expect { sent_request(io:) }.to raise_error(Squishling::InputRejectedError)
      expect(io.pos).to eq(3)
    end

    it "doesn't treat an upload without a tempfile, or a stream that can't read a length, as a file" do
      upload = upload_class.new(nil, "image/png", "r.png")
      odd = Class.new do
        def read = "x"
        def rewind = nil
        def to_squishling = "odd"
      end.new

      expect(sent_request(upload:, odd:).images).to be_empty
    end

    it "reads a stream that answers #read through method_missing, or has a #method of its own" do
      proxy = Class.new do
        def respond_to?(name, include_all = false) # rubocop:disable Style/OptionalBooleanParameter -- mirrors Object
          %i[read rewind].include?(name) || super
        end

        def method_missing(name, *)
          if name == :read
            "x"
          else
            (name == :rewind ? nil : super)
          end
        end

        def respond_to_missing?(*) = false
      end.new
      odd = Class.new do
        attr_reader :method

        def read(_length = nil) = "plain text"
        def rewind = nil
      end.new

      expect(sent_request(proxy:, odd:).arguments).to eq("proxy" => "x", "odd" => "plain text")
    end

    it "never reads a class, a Dir or a terminal as a file" do
      [StringIO, Dir].each do |value|
        expect { sent_request(value:) }.to raise_error(Squishling::ConfigurationError, /can't be sent as JSON/)
      end
    end

    it "ignores a declared type that isn't shaped like one" do
      blob = blob_class.new("data", "text/x\nINJECT")

      expect(sent_request(blob:).arguments["blob"]).to eq("data")
    end
  end

  describe "real ActiveStorage shapes" do
    it "sends one image for a has_one_attached slot whose blob has attachments of its own" do
      delegating = Class.new do
        def initialize(attachment) = @attachment = attachment
        def attached? = true
        attr_reader :attachment

        # Attached::One delegates what it doesn't define to its attachment, which delegates to its blob; a blob
        # has_many :attachments.
        def respond_to_missing?(name, include_private = false) = name == :attachments || super
        def attachments = [@attachment]
      end
      blob = blob_class.new(png, "image/png")

      request = sent_request(photo: delegating.new(blob))

      expect(request.arguments["photo"]).to eq("attached_image" => 1)
      expect(request.images.size).to eq(1)
    end
  end

  describe "a file that can't be read, continued" do
    it "carries no cause that names the file" do
      error = begin
        sent_request(file: Pathname(File.join(@dir, "missing.png")))
      rescue Squishling::InputRejectedError => e
        e
      end

      expect(error.cause).to be_nil
      expect(error.message).not_to include("missing")
    end

    it "lets a failure of the developer's own object propagate as it was" do
      blob = blob_class.new(png, nil)
      allow(blob).to receive(:download).and_raise(Errno::ECONNRESET)

      expect { sent_request(blob:) }.to raise_error(Errno::ECONNRESET)
    end

    it "bounds the read of a stream whose size isn't known" do
      Squishling.configure { |config| config.max_file_bytes = 10 }
      stream = Class.new do
        def initialize = @reads = []
        attr_reader :reads

        def rewind = nil
        def read(length = nil) = (@reads << length) && ("x" * (length || 1_000))
      end.new

      expect { sent_request(stream:) }
        .to raise_error(Squishling::InputRejectedError, /over max_file_bytes/)
      expect(stream.reads).to eq([11])
    ensure
      Squishling.reset_config!
    end

    it "stops reading plain files once there are too many" do
      Squishling.configure { |config| config.max_files = 2 }
      paths = Array.new(5) { |n| Pathname(write("#{n}.png", "#{png}#{n}")) }
      reads = []
      allow(File).to(receive(:binread).and_wrap_original do |original, *args|
        (reads << args.first) && original.call(*args)
      end)

      expect { sent_request(paths:) }.to raise_error(Squishling::InputRejectedError, /3 files is over max_files/)
      expect(reads.size).to eq(3)
    ensure
      Squishling.reset_config!
    end
  end

  describe "a file that can't be sent" do
    let(:tiff) { "II*\x00#{'x' * 20}".b }

    it "is refused after the sanitizers, naming the type and where it was" do
      expect { sent_request(fax: blob_class.new(tiff, "image/tiff")) }
        .to raise_error(Squishling::InputRejectedError,
          %r{ReceiptReader#call: arguments\.fax: image/tiff can't be sent})
    end

    it "refuses a file of a type nobody could identify" do
      expect { sent_request(blob: blob_class.new("\x00\x01\x02\xFF".b, nil)) }
        .to raise_error(Squishling::InputRejectedError, %r{application/octet-stream can't be sent})
    end

    it "doesn't quote a declared type it doesn't know" do
      expect { sent_request(blob: blob_class.new("\x00\x01\xFF".b, "application/x-patient-jane-doe")) }
        .to raise_error(Squishling::InputRejectedError) { |error|
          expect(error.message).to include("an unrecognized file type can't be sent")
          expect(error.message).not_to include("jane")
        }
    end

    it "refuses an empty file" do
      expect { sent_request(empty: StringIO.new("")) }
        .to raise_error(Squishling::InputRejectedError, /a file is empty/)
    end

    it "is not absorbed by squish_fallback and makes no request" do
      fake = fake_squishling { |llm| llm.step(:any).reply(answer) }
      klass.squish_fallback { |*| { total_cents: 0 } }

      expect { klass.call(fax: blob_class.new(tiff, nil)) }.to raise_error(Squishling::InputRejectedError)
      expect(fake.requests).to be_empty
    end

    it "lists every file that can't be sent at once, by path" do
      expect do
        sent_request(pages: [blob_class.new(tiff, nil), blob_class.new(png, nil), blob_class.new("#{tiff}2", nil)])
      end
        .to raise_error(Squishling::InputRejectedError) { |error|
          expect(error.rejections.map(&:path)).to eq(["arguments.pages[0]", "arguments.pages[2]"])
        }
    end
  end

  describe "PDFs" do
    let(:pdf) { "%PDF-1.7\n%\xE2\xE3\xCF\xD3\n1 0 obj".b }

    it "are sent as documents, numbered apart from images" do
      request = sent_request(scan: blob_class.new(pdf, "application/pdf"), photo: StringIO.new(png),
        more: Pathname(write("b.pdf", "#{pdf}2")))

      expect(request.arguments).to eq("scan" => { "attached_document" => 1 }, "photo" => { "attached_image" => 1 },
        "more" => { "attached_document" => 2 })
      expect(request.documents.map(&:media_type)).to eq(%w[application/pdf application/pdf])
      expect(request.images.size).to eq(1)
      expect(request.system_prompt).to include(Squishling::Invoker::DOCUMENT_NOTE, Squishling::Invoker::IMAGE_NOTE)
    end

    it "are recognized in a binary String, which is what #download and File.binread return" do
      request = sent_request(scan: pdf)

      expect(request.arguments["scan"]).to eq("attached_document" => 1)
    end

    it "are not guessed from a text String that happens to start like one" do
      request = sent_request(note: "%PDF-1.7 is how a PDF starts")

      expect(request.documents).to be_empty
      expect(request.arguments["note"]).to eq("%PDF-1.7 is how a PDF starts")
    end

    it "show only a type Squishling knows when inspected" do
      odd = Squishling::Document.new(data: "abc", media_type: "application/x-patient-jane")

      expect(odd.inspect).to eq("#<Squishling::Document an unrecognized type, 3 bytes>")
      expect(odd.to_json).not_to include("jane")
    end

    it "keep their bytes out of inspect, JSON, and Marshal like an image" do
      document = Squishling::Document.new(data: pdf, media_type: "application/pdf")

      expect(document.inspect).to eq("#<Squishling::Document application/pdf, #{pdf.bytesize} bytes>")
      expect(document.to_json).to eq(JSON.generate(document.inspect))
      expect { Marshal.dump(document) }.to raise_error(TypeError, /can't be dumped/)
      expect(document).to eq(Squishling::Document.new(data: pdf.dup, media_type: "application/pdf"))
    end

    it "go through a judge and a chat, and are refused by a System One judgment" do
      klass.squishling(harness: { type: :judged_squishsum, judge: { model: "jev", type: :judgment } })
      fake_squishling do |llm|
        llm.sample("a").reply(answer)
        llm.sample("b").reply(answer)
      end

      expect { klass.call(scan: pdf) }
        .to raise_error(Squishling::ConfigurationError, /:judgment can't see the call's files/)
    end
  end

  describe "text files" do
    it "arrive as a String, so a sanitizer treats them like any other text" do
      hl7 = Pathname(write("adt.hl7", "MSH|^~\\&|A\rPID|1||123^^^MRN"))
      json = StringIO.new('{"resourceType":"Patient"}')
      declared = blob_class.new("a,b\n1,2", "text/csv")

      request = sent_request(hl7:, json:, declared:)

      expect(request.arguments).to eq("hl7" => "MSH|^~\\&|A\rPID|1||123^^^MRN",
        "json" => '{"resourceType":"Patient"}', "declared" => "a,b\n1,2")
      expect(request.images).to be_empty
    end

    it "arrive as the text a binary String of UTF-8 holds" do
      expect(sent_request(note: "caf\u00e9".b).arguments["note"]).to eq("caf\u00e9")
    end

    it "go through as a Document when they aren't valid UTF-8, for a sanitizer to decode" do
      latin = Pathname(write("lab.hl7", "MSH|caf\xE9".b))

      expect { sent_request(latin:) }
        .to raise_error(Squishling::InputRejectedError, %r{arguments\.latin: application/hl7-v2 can't be sent})
    end
  end

  describe "an input that isn't a file" do
    it "names the file that can't be read by its path, masking a Hash key that is data" do
      expect { sent_request(patients: { "Jane Doe 123-45-6789" => Pathname(File.join(@dir, "missing.png")) }) }
        .to raise_error(Squishling::InputRejectedError) { |error|
          expect(error.rejections.map(&:path)).to eq(["arguments.patients[key]"])
          expect(error.message).not_to include("Jane")
        }
    end

    it "refuses a binary String that is neither a known file nor text, without quoting it" do
      expect { sent_request(blob: "\xFF\xFE\x00junk".b) }
        .to raise_error(Squishling::InputRejectedError, /arguments\.blob: a binary String is neither/)
    end

    it "sends an Exception as its class and message, the message as any String" do
      request = sent_request(error: RuntimeError.new("boom"))

      expect(request.arguments["error"]).to eq("class" => "RuntimeError", "message" => "boom")
    end

    it "doesn't count text Strings, binary or not, as files" do
      texts = (1..25).map { |n| "abc#{n}".b }

      expect(sent_request(texts:).arguments["texts"].size).to eq(25)
    end

    it "sends a String in another encoding as UTF-8, and refuses one that can't be" do
      latin = "caf\xE9".dup.force_encoding("ISO-8859-1")

      expect(sent_request(note: latin).arguments["note"]).to eq("caf\u00e9")
      expect { sent_request(note: "\xE9".dup.force_encoding("US-ASCII")) }
        .to raise_error(Squishling::InputRejectedError, /arguments\.note: a String can't be converted to UTF-8/)
    end

    it "refuses an invalid String of any encoding, naming where it was" do
      expect { sent_request(error: RuntimeError.new("caf\xFF")) }
        .to raise_error(Squishling::InputRejectedError,
          /arguments\.error\.message: a String can't be converted to UTF-8/)
    end

    it "carries no cause that holds the bytes of a String it can't convert" do
      error = begin
        sent_request(note: "caf\xE9".dup.force_encoding("US-ASCII"))
      rescue Squishling::InputRejectedError => e
        e
      end

      expect(error.cause).to be_nil
    end

    it "sends keys as JSON does, and refuses two that are one once sent" do
      expect(sent_request(info: { ssn: "1", "name" => "n" }).arguments["info"]).to eq("ssn" => "1", "name" => "n")
      expect { sent_request(info: { "k" => 1, k: 2 }) }
        .to raise_error(Squishling::InputRejectedError, /arguments\.info: two keys are the same/)
    end

    it "refuses a value JSON can't carry, and one nested too deeply, without quoting them" do
      deep = (1..150).reduce("x") { |inner, _| [inner] }

      expect { sent_request(deep:) }.to raise_error(Squishling::InputRejectedError, /nested too deeply/)
    end

    it "refuses a value JSON can't carry, without quoting it" do
      expect { sent_request(ratio: Float::NAN) }
        .to raise_error(Squishling::InputRejectedError, /arguments\.ratio: an input holds a value JSON can't represent/)
    end
  end

  describe "limits" do
    after { Squishling.reset_config! }

    it "refuses too many files, and a file that is too large" do
      Squishling.configure { |config| config.max_files = 2 }
      files = Array.new(3) { |n| blob_class.new("#{png}#{n}", nil) }
      expect { sent_request(files:) }
        .to raise_error(Squishling::InputRejectedError, /3 files is over max_files \(2\)/)

      Squishling.configure do |config|
        config.max_files = nil
        config.max_file_bytes = 10
      end
      expect { sent_request(file: blob_class.new(png, nil)) }
        .to raise_error(Squishling::InputRejectedError, /a file of 28 bytes is over max_file_bytes \(10\)/)
    end

    it "counts an explicit Image too" do
      Squishling.configure { |config| config.max_file_bytes = 10 }

      expect { sent_request(image: Squishling::Image.new(data: png)) }
        .to raise_error(Squishling::InputRejectedError, /arguments\.image: 28 bytes is over max_file_bytes \(10\)/)
    end

    it "refuses a large file before reading it" do
      Squishling.configure { |config| config.max_file_bytes = 10 }
      big = blob_class.new(png, nil)
      allow(big).to receive(:download).and_raise("must not be read")

      expect { sent_request(big:) }
        .to raise_error(Squishling::InputRejectedError, /of 28 bytes is over max_file_bytes/)
    end

    it "refuses a collection with too many files before reading any" do
      Squishling.configure { |config| config.max_files = 1 }
      files = Array.new(2) do
        blob_class.new(png, nil).tap { |blob| allow(blob).to receive(:download).and_raise("read") }
      end

      expect { sent_request(many: many_class.new(files)) }
        .to raise_error(Squishling::InputRejectedError, /2 files is over max_files \(1\)/)
    end

    it "takes only positive integers or nil" do
      expect { Squishling.config.max_files = 0 }.to raise_error(Squishling::ConfigurationError, /max_files/)
    end
  end

  describe "adapter media types" do
    let(:text_only) do
      RubyLLM.models.all.find do |model|
        model.modalities.input.any? && !model.modalities.input.intersect?(%w[image pdf])
      end
    end
    let(:vision_without_pdf) do
      RubyLLM.models.all.find do |model|
        model.modalities.input.include?("image") && !model.modalities.input.include?("pdf")
      end
    end
    let(:pdf) { "%PDF-1.7\n1 0 obj".b }

    it "has the OpenAI-compatible adapter take only the types it was given" do
      adapter = Squishling::Adapters::OpenAICompatible.new(media_types: %w[image/png image/jpeg])
      Squishling.configure { |config| config.adapter = adapter }

      expect { klass.call(file: blob_class.new("RIFF....WEBPxxxx".b, nil)) }
        .to raise_error(Squishling::ConfigurationError, %r{image/webp files, but the .* takes image/png, image/jpeg})
    ensure
      Squishling.reset_config!
    end

    it "reads PDF by default only from OpenAI's own endpoint" do
      openai = Squishling::Adapters::OpenAICompatible.new(api_key: "k")
      local = Squishling::Adapters::OpenAICompatible.new(base_url: "http://localhost:11434/v1")

      expect(openai.media_types).to include("application/pdf")
      expect(local.media_types).not_to include("application/pdf")
      expect(Squishling::Adapters::OpenAICompatible.new(base_url: "http://localhost:1/v1",
        media_types: %w[application/pdf]).media_types).to eq(%w[application/pdf])
    end

    it "refuses a PDF a local server wasn't told it takes, before any request" do
      Squishling.configure { |config| config.adapter = Squishling::Adapters::OpenAICompatible.new(base_url: "http://localhost:1/v1") }

      expect { klass.call(scan: pdf) }
        .to raise_error(Squishling::ConfigurationError, %r{application/pdf files, but the .* takes image/png})
    ensure
      Squishling.reset_config!
    end

    it "sends a PDF to the OpenAI-compatible adapter as a file part" do
      document = Squishling::Document.new(data: pdf, media_type: "application/pdf")
      parts = Squishling::Adapters::OpenAIContent.of([{ type: :text, text: "hi" }, { type: :file, file: document }])
      data_uri = "data:application/pdf;base64,#{[pdf].pack('m0')}"

      expect(parts.last).to eq("type" => "file", "file" => { "filename" => "document.pdf", "file_data" => data_uri })
    end

    it "checks the OpenAI-compatible media_types option" do
      expect { Squishling::Adapters::OpenAICompatible.new(media_types: %w[image/tiff]) }
        .to raise_error(Squishling::ConfigurationError, /media_types/)
    end

    it "has RubyLLM take what the model's modalities say, and leave PDF to the provider for a vision model" do
      adapter = Squishling::Adapters::RubyLLM.new
      step = Struct.new(:model, :provider)
      all = [*Squishling::Image::MEDIA_TYPES.keys, "application/pdf"]

      expect(adapter.media_types(step.new(nil, nil))).to eq(all)
      expect(adapter.media_types(step.new("no-such-model", nil))).to eq(all)
      expect(adapter.media_types(step.new(vision_without_pdf.id, vision_without_pdf.provider.to_sym))).to eq(all)
      skip "RubyLLM knows no text-only model" unless text_only
      expect(adapter.media_types(step.new(text_only.id, text_only.provider.to_sym))).to eq([])
    end

    it "gives a custom adapter that only has images? the images, not documents" do
      adapter = Class.new(Squishling::Adapter::Base) do
        def images? = true
        def complete(_request) = raise("no request should be made")
      end.new
      Squishling.configure { |config| config.adapter = adapter }

      expect { klass.call(scan: pdf) }.to raise_error(Squishling::ConfigurationError, %r{application/pdf files})
    ensure
      Squishling.reset_config!
    end
  end
end
