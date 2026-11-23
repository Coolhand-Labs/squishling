# frozen_string_literal: true

require "squishling/testing"

RSpec.describe "Images in a squished call" do # rubocop:disable RSpec/DescribeClass
  include Squishling::Testing::RSpec

  let(:klass) do
    Class.new do
      include Squishling

      squishling escalation: [{ model: "small", attempts: 2 }, "large"]
      purpose "Read the receipt."
      output_schema do
        integer :total_cents
      end

      def self.to_s = "ReceiptReader"
    end
  end

  let(:png) { "\x89PNG\r\n\x1A\n#{'x' * 20}".b }
  let(:image) { Squishling::Image.new(data: png) }
  let(:other) { Squishling::Image.from_url("https://example.com/back.png") }
  let(:answer) { { "total_cents" => 1234 } }

  it "puts a placeholder in the input and sends the images after the text of the first message" do
    fake = fake_squishling { |llm| llm.step(:any).reply(answer) }

    expect(klass.call(image:, pages: [other], note: "lunch").total_cents).to eq(1234)

    request = fake.requests.first
    expect(request.arguments).to eq("image" => { "attached_image" => 1 }, "pages" => [{ "attached_image" => 2 }],
      "note" => "lunch")
    expect(request.images).to eq([image, other])
    expect(request.messages.first[:content].first).to eq(type: :text, text: JSON.generate(request.payload))
    expect(request.system_prompt).to include(Squishling::Invoker::IMAGE_NOTE)
  end

  it "sends an image from squish_context, or nested in a Hash inside an Array" do
    klass.squish_context :badge
    klass.define_method(:badge) { Squishling::Image.from_url("https://example.com/badge.png") }
    fake = fake_squishling { |llm| llm.step(:any).reply(answer) }

    klass.call(pages: [{ front: image }])

    request = fake.requests.first
    expect(request.arguments).to eq("pages" => [{ "front" => { "attached_image" => 1 } }])
    expect(request.payload["context"]).to eq("badge" => { "attached_image" => 2 })
    expect(request.images.size).to eq(2)
  end

  it "sends an image in a squish! call's context:" do
    stamp = image
    klass.define_method(:call) { |note:| squish!(context: { stamp: }) if note }
    fake = fake_squishling { |llm| llm.step(:any).reply(answer) }

    klass.call(note: "stamped")

    expect(fake.requests.first.payload["context"]).to eq("stamp" => { "attached_image" => 1 })
    expect(fake.requests.first.images.size).to eq(1)
  end

  it "attaches an image passed twice once" do
    fake = fake_squishling { |llm| llm.step(:any).reply(answer) }

    klass.call(front: image, again: image)

    expect(fake.requests.first.arguments)
      .to eq("front" => { "attached_image" => 1 }, "again" => { "attached_image" => 1 })
    expect(fake.requests.first.images).to eq([image])
  end

  it "sends text alone, without the image note, when the call has no images" do
    fake = fake_squishling { |llm| llm.step(:any).reply(answer) }

    klass.call(note: "lunch")

    expect(fake.requests.first.messages.first[:content]).to be_a(String)
    expect(fake.requests.first.system_prompt).not_to include("attached")
    expect(fake.requests.first.images).to eq([])
  end

  it "sends the images once per chat: a retry continues the chat, an escalation starts a new one with them" do
    fake = fake_squishling do |llm|
      llm.step("small").reply({ "total_cents" => "x" }, { "total_cents" => "y" })
      llm.step("large").reply(answer)
    end

    klass.call(image:)

    retry_request, escalation = fake.requests.drop(1)
    expect(retry_request.messages.last[:content]).to be_a(String)
    expect(retry_request.images).to eq([image])
    expect(escalation.conversation).not_to eq(retry_request.conversation)
    expect(escalation.images).to eq([image])
    expect(escalation.errors).not_to be_empty
  end

  it "keeps the bytes out of squawk reports" do
    fake_squishling { |llm| llm.step(:any).reply(answer) }

    capture = Squishling::Testing.with_squawk { klass.call(image:) }

    expect(capture.calls.first.metadata[:input]).to eq(JSON.generate(arguments: { image: { attached_image: 1 } }))
  end

  it "shows the images in a preview" do
    preview = Squishling::Testing.preview(klass, image:)

    expect(preview[:images]).to eq([image])
    expect(preview[:user_message]).to include('"attached_image":1')
  end

  it "refuses an adapter that doesn't take images, before any request" do
    adapter = Class.new(Squishling::Adapter::Base) do
      def complete(_request) = raise("no request should be made")
    end.new
    Squishling.configure { |config| config.adapter = adapter }

    expect { klass.call(image:) }.to raise_error(Squishling::ConfigurationError, /has images, but the .* adapter/)
  end

  describe "judges" do
    let(:samples) { [{ "total_cents" => 1 }, { "total_cents" => 2 }] }

    it "sends a chat judge the images with the input" do
      klass.squishling(harness: { type: :judged_squishsum, judge: "opus" })
      fake = fake_squishling do |llm|
        llm.sample("a").reply(samples.first)
        llm.sample("b").reply(samples.last)
        llm.judge.verdict(:b)
      end

      expect(klass.call(image:).total_cents).to eq(2)

      judge = fake.requests_for(role: :judge).first
      expect(judge.images).to eq([image])
      expect(judge.arguments).to eq("image" => { "attached_image" => 1 })
      expect(judge.system_prompt).to include(Squishling::Invoker::IMAGE_NOTE)
      expect(fake.requests_for(role: :sample).map(&:images)).to all(eq([image]))
    end

    it "refuses a System One judgment, which can't see them" do
      klass.squishling(harness: { type: :judged_squishsum, judge: { model: "jev", type: :judgment } })
      fake_squishling do |llm|
        llm.sample("a").reply(samples.first)
        llm.sample("b").reply(samples.last)
      end

      expect { klass.call(image:) }
        .to raise_error(Squishling::ConfigurationError, /:judgment can't see the call's images/)
    end
  end
end
