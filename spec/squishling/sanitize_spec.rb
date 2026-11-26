# frozen_string_literal: true

require "squishling/testing"
require_relative "../support/sent_request"
require "stringio"

RSpec.describe "squish_sanitize" do # rubocop:disable RSpec/DescribeClass
  include Squishling::Testing::RSpec
  include SentRequest

  let(:klass) do
    Class.new do
      include Squishling

      squishling model: "vision"
      purpose "Summarize the chart."
      output_schema { integer :total }

      def self.to_s = "ChartReader"
    end
  end

  let(:answer) { { "total" => 1 } }
  let(:png) { "\x89PNG\r\n\x1A\n#{'x' * 20}".b }
  let(:tiff) { "II*\x00#{'t' * 20}".b }
  let(:hl7) { "MSH|^~\\&|EPIC\rPID|1||123-45-6789^^^MRN||DOE^JANE" }
  let(:fhir) do
    { "resourceType" => "Bundle", "entry" => [{ "resource" => { "resourceType" => "Patient", "ssn" => "123-45-6789",
                                                                "name" => [{ "family" => "Doe" }] } }] }
  end

  def blob(bytes, type = nil)
    Class.new do
      define_method(:download) { bytes }
      define_method(:content_type) { type }
      define_method(:byte_size) { bytes.bytesize }
    end.new
  end

  describe "without a sanitizer" do
    it "sends HL7 and FHIR as the text and JSON they are" do
      request = sent_request(message: hl7, bundle: fhir)

      expect(request.arguments).to eq("message" => hl7, "bundle" => fhir)
    end
  end

  describe "what it is offered" do
    it "offers every node, parents first, with its path" do
      seen = []
      klass.squish_sanitize do |value:, path:, **|
        seen << [path, value.class]
        value
      end

      sent_request(patient: { name: ["Jane"] }, age: 3)

      expect(seen).to eq([["arguments", Hash], ["arguments.patient", Hash], ["arguments.patient.name", Array],
                          ["arguments.patient.name[0]", String], ["arguments.age", Integer]])
    end

    it "offers a Struct as its members, and a file as an Image, a Document, or text" do
      kinds = []
      klass.squish_sanitize do |value:, **|
        kinds << value.class unless value.is_a?(Hash)
        value
      end
      member = Struct.new(:mrn)

      # The fax is refused after the sanitizer has seen everything, so every kind was offered.
      expect do
        sent_request(member: member.new("123"), photo: StringIO.new(png), fax: blob(tiff), note: Pathname(__FILE__))
      end
        .to raise_error(Squishling::InputRejectedError)
      expect(kinds).to include(String, Squishling::Image, Squishling::Document)
    end

    it "offers squish_context values and a squish! call's context, as context" do
      paths = []
      klass.squish_context :mrn
      klass.define_method(:mrn) { "123" }
      klass.squish_sanitize { |value:, path:, **| (paths << path) && value }
      fake_squishling { |llm| llm.step(:any).reply(answer) }

      klass.call(note: "x")

      expect(paths).to include("context.mrn")
    end

    it "takes only the keywords it declares, and checks them when declared" do
      klass.squish_sanitize { |value:, **| value }
      expect { sent_request(a: 1) }.not_to raise_error

      expect { klass.squish_sanitize { |value| value } }
        .to raise_error(Squishling::ConfigurationError, /called with keywords/)
      expect { klass.squish_sanitize { |value:, secrets:| [value, secrets] } }
        .to raise_error(Squishling::ConfigurationError, /unknown keyword/)
    end

    it "runs against the instance" do
      klass.define_method(:mask) { "[REDACTED]" }
      klass.squish_sanitize { |value:, **| value == "secret" ? mask : value }

      expect(sent_request(note: "secret").arguments["note"]).to eq("[REDACTED]")
    end
  end

  describe "what it can do" do
    it "is offered Hash keys as Strings whatever they were, so a Symbol key is found by its name" do
      klass.squish_sanitize { |value:, **| value.is_a?(Hash) ? value.except("ssn") : value }

      expect(sent_request(info: { ssn: "1", name: "n" }).arguments["info"]).to eq("name" => "n")
    end

    it "redacts a String, drops a field, and removes an array element, by value and path" do
      klass.squish_sanitize do |value:, path:, **|
        case value
        when String then value.gsub(/\b\d{3}-\d{2}-\d{4}\b/, "[SSN]")
        when Hash then path.end_with?(".resource") ? value.except("ssn") : value
        else value
        end
      end

      request = sent_request(message: hl7, bundle: fhir)

      expect(request.arguments["message"]).to eq("MSH|^~\\&|EPIC\rPID|1||[SSN]^^^MRN||DOE^JANE")
      expect(request.arguments["bundle"]["entry"][0]["resource"]).to eq("resourceType" => "Patient",
        "name" => [{ "family" => "Doe" }])
    end

    it "parses a String it is offered, and is then offered what it returned" do
      klass.squish_sanitize { |value:, path:, **| path == "arguments.raw" ? JSON.parse(value) : value }
      paths = []
      klass.squish_sanitize { |value:, path:, **| (paths << path) && value }

      request = sent_request(raw: '{"a":{"b":1}}')

      expect(request.arguments["raw"]).to eq("a" => { "b" => 1 })
      expect(paths).to include("arguments.raw.a.b")
    end

    it "converts a file the adapters can't take, and the converted one is sent" do
      bytes = png
      klass.squish_sanitize do |value:, **|
        value.is_a?(Squishling::Document) && value.media_type == "image/tiff" ? StringIO.new(bytes) : value
      end

      request = sent_request(fax: blob(tiff, "image/tiff"))

      expect(request.arguments["fax"]).to eq("attached_image" => 1)
      expect(request.images.first.media_type).to eq("image/png")
    end

    it "doesn't count converted files again against max_files" do
      Squishling.configure { |config| config.max_files = 3 }
      pdf = "%PDF-1.7\nconverted".b
      klass.squish_sanitize { |value:, **| value.is_a?(Squishling::Document) ? pdf.dup : value }

      request = sent_request(fax: (1..3).map { |n| "II*\x00#{n}".b + ("t" * 10) })

      expect(request.documents.size).to eq(1)
    ensure
      Squishling.reset_config!
    end

    it "still holds what it returns to max_files and max_file_bytes" do
      Squishling.configure { |config| config.max_files = 2 }
      klass.squish_sanitize { |value:, **| value == "split" ? (1..5).map { |n| StringIO.new("%PDF-1.7 #{n}") } : value }

      expect { sent_request(note: "split") }
        .to raise_error(Squishling::InputRejectedError, /3 files is over max_files \(2\)/)

      Squishling.configure do |config|
        config.max_files = nil
        config.max_file_bytes = 10
      end
      klass.squish_sanitize { |value:, **| value == "big" ? StringIO.new("%PDF-1.7 #{'x' * 20}") : value }
      expect { sent_request(note: "big") }
        .to raise_error(Squishling::InputRejectedError, /arguments\.note: a file of \d+ bytes is over max_file_bytes/)
    ensure
      Squishling.reset_config!
    end

    it "offers an Exception's message as the String it is" do
      paths = []
      klass.squish_sanitize { |value:, path:, **| (paths << path) && value }

      sent_request(error: RuntimeError.new("boom"))

      expect(paths).to include("arguments.error", "arguments.error.message")
    end

    it "still refuses what it leaves unconverted, naming where it was" do
      klass.squish_sanitize { |value:, **| value }

      expect { sent_request(fax: blob(tiff, "image/tiff")) }
        .to raise_error(Squishling::InputRejectedError, %r{arguments\.fax: image/tiff can't be sent})
    end

    it "sends what it returns even when that is nil" do
      klass.squish_sanitize { |value:, **| value.is_a?(String) ? nil : value }

      expect(sent_request(note: "x").arguments["note"]).to be_nil
    end
  end

  describe "what it is handed" do
    it "is the plain data an object's to_squishling returns, so what would be sent is offered, not the model" do
      patient = Class.new do
        def to_squishling = { name: "Jane Doe", ssn: "123-45-6789" }
      end.new
      klass.squish_sanitize { |value:, **| value.is_a?(String) ? value.gsub(/\d{3}-\d{2}-\d{4}/, "[SSN]") : value }

      expect(sent_request(patient:).arguments["patient"]).to eq("name" => "Jane Doe", "ssn" => "[SSN]")
    end

    it "is read like any input even when it is the same node, changed in place" do
      klass.squish_sanitize do |value:, **|
        value[:photo] = StringIO.new("\x89PNG\r\n\x1A\n#{'x' * 20}".b) if value.is_a?(Hash) && value.key?("note")
        value
      end

      request = sent_request(info: { note: "x" })

      expect(request.arguments["info"]["photo"]).to eq("attached_image" => 1)
    end

    it "refuses a node a sanitizer made contain itself, rather than overflowing the stack" do
      klass.squish_sanitize do |value:, **|
        value[:self] = value if value.is_a?(Hash) && value.key?("note")
        value
      end

      expect { sent_request(info: { note: "x" }) }
        .to raise_error(Squishling::ConfigurationError, /contains itself/)
    end

    it "is a copy: a sanitizer that changes a String in place leaves the caller's alone" do
      klass.squish_sanitize { |value:, **| value.is_a?(String) ? value.gsub!("secret", "[X]") && value : value }
      original = +"a secret"

      expect(sent_request(note: original).arguments["note"]).to eq("a [X]")
      expect(original).to eq("a secret")
    end

    it "refuses a sanitizer declared with nothing" do
      expect { klass.squish_sanitize }.to raise_error(Squishling::ConfigurationError, /needs a block or a callable/)
    end
  end

  describe "rejecting" do
    it "lists every problem at once, across files in an Array, and makes no request" do
      klass.squish_sanitize do |value:, reject:, **|
        reject.call("not a PNG") if value.is_a?(Squishling::Image) && value.media_type != "image/png"
        reject.call(["too short", "no good"]) if value == "hi"
        value
      end
      fake = fake_squishling { |llm| llm.step(:any).reply(answer) }
      jpeg = "\xFF\xD8\xFF\xE0#{'y' * 20}".b

      expect { klass.call(pages: [StringIO.new(jpeg), StringIO.new(png), StringIO.new("#{jpeg}2")], note: "hi") }
        .to raise_error(Squishling::InputRejectedError) { |error|
          expect(error.rejections.map { |r| [r.path, r.message] }).to eq(
            [["arguments.pages[0]", "not a PNG"], ["arguments.pages[2]", "not a PNG"],
             ["arguments.note", "too short"], ["arguments.note", "no good"]]
          )
          expect(error.message).to start_with("ChartReader#call: arguments.pages[0]: not a PNG")
        }
      expect(fake.requests).to be_empty
    end

    it "is not absorbed by squish_fallback" do
      klass.squish_sanitize { |value:, reject:, **| reject.call("no") if value == "x" || value }
      klass.squish_fallback { |*| { total: 0 } }

      expect { sent_request(note: "x") }.to raise_error(Squishling::InputRejectedError)
    end

    it "uses a default message when it gives none" do
      klass.squish_sanitize { |value:, reject:, **| value == "x" ? reject.call : value }

      expect { sent_request(note: "x") }.to raise_error(Squishling::InputRejectedError, /rejected by the sanitizer/)
    end

    it "fails closed when the sanitizer raises: nothing is sent, and the error is its own" do
      klass.squish_sanitize { |**| raise KeyError, "boom" }
      fake = fake_squishling { |llm| llm.step(:any).reply(answer) }

      expect { klass.call(note: "x") }.to raise_error(KeyError, "boom")
      expect(fake.requests).to be_empty
    end
  end

  describe "levels" do
    after { Squishling.reset_config! }

    it "run in order: the configuration's, each class in the chain, then the method's" do
      order = []
      noting = ->(name) { ->(value:, **) { value.tap { order << name if value == "x" } } }
      Squishling.configure { |config| config.sanitizer = noting.call(:config) }
      klass.squish_sanitize(noting.call(:parent))
      child = Class.new(klass) do
        def self.to_s = "Child"
      end
      child.squish_sanitize(noting.call(:child))
      child.squish :call, sanitize: noting.call(:method)
      fake_squishling { |llm| llm.step(:any).reply(answer) }

      child.call(note: "x")

      expect(order).to eq(%i[config parent child method])
    end

    it "each see what the one before returned" do
      klass.squish_sanitize { |value:, **| value.is_a?(String) ? "#{value}1" : value }
      klass.squish_sanitize { |value:, **| value.is_a?(String) ? "#{value}2" : value }

      expect(sent_request(note: "x").arguments["note"]).to eq("x12")
    end

    it "can't be switched off with false" do
      expect { klass.squish_sanitize(false) }.to raise_error(Squishling::ConfigurationError, /switched off/)
      expect { Squishling.config.sanitizer = false }.to raise_error(Squishling::ConfigurationError, /switched off/)
      expect { klass.squish :call, sanitize: false }.to raise_error(Squishling::ConfigurationError, /switched off/)
    end
  end

  describe "what keeps the raw input" do
    it "is the Ruby path, squish_when, and squish_fallback" do
      seen = {}
      klass.squish_sanitize { |value:, **| value.is_a?(String) ? "[X]" : value }
      klass.squish_when { |note:, **| (seen[:when] = note) && false }
      klass.define_method(:call) { |note:| (seen[:ruby] = note) && { total: 1 } }

      klass.call(note: "secret")

      expect(seen).to eq(when: "secret", ruby: "secret")
    end

    it "reaches the fallback unsanitized" do
      fallback_saw = nil
      klass.squish_sanitize { |value:, **| value.is_a?(String) ? "[X]" : value }
      klass.squish_fallback { |_error, note:| (fallback_saw = note) && { total: 0 } }
      fake_squishling { |llm| llm.step(:any).fail(:server_error) }

      klass.call(note: "secret")

      expect(fallback_saw).to eq("secret")
    end
  end

  describe "what is sanitized downstream" do
    it "is what a squawk report, a preview, and a retry's judge see" do
      klass.squish_sanitize { |value:, **| value.is_a?(String) ? "[X]" : value }
      fake_squishling { |llm| llm.step(:any).reply(answer) }

      capture = Squishling::Testing.with_squawk { klass.call(note: "secret") }

      expect(capture.calls.first.metadata[:input]).to eq(JSON.generate(arguments: { note: "[X]" }))
      expect(Squishling::Testing.preview(klass, note: "secret")[:user_message]).to include("[X]")
    end

    it "is what a judge is sent" do
      klass.squishling(harness: { type: :judged_squishsum, judge: "jev" })
      klass.squish_sanitize { |value:, **| value.is_a?(String) ? "[X]" : value }
      fake = fake_squishling do |llm|
        llm.sample("a").reply({ "total" => 1 })
        llm.sample("b").reply({ "total" => 2 })
        llm.judge.reply({ "verdict" => "a", "reason" => "r" })
      end

      klass.call(note: "secret")

      expect(fake.requests_for(role: :judge).first.arguments).to eq("note" => "[X]")
    end
  end

  describe "an apprentice's shadow run" do
    it "reports a rejection as its error and still returns the Ruby result" do
      reports = []
      shadowed = Class.new do
        include Squishling

        squishling model: "vision", apprentice_mode: { report: ->(**report) { reports << report } }
        purpose "Summarize."
        output_schema { integer :total }
        squish_sanitize { |value:, reject:, **| value == "secret" ? reject.call("no PHI") : value }

        def self.to_s = "Shadowed"
        def call(note:) = note && { total: 1 }
      end
      fake = fake_squishling { |llm| llm.step(:any).reply(answer) }

      result = shadowed.call(note: "secret")

      expect(result.total).to eq(1)
      expect(reports.first[:error]).to be_a(Squishling::InputRejectedError)
      expect(fake.requests).to be_empty
    end
  end
end
