# frozen_string_literal: true

require "squishling/testing"

RSpec.describe Squishling::Testing::Direct do
  include Squishling::Testing::RSpec

  let(:klass) do
    Class.new do
      include Squishling

      squishling escalation: [{ model: "a", priority: 1 }, { model: "b", priority: 1 }], params: { temperature: 0 }
      purpose "Propose a regex."
      append_to_purpose "Keep it short."
      squish_context :tenant
      output_schema do
        string :regex
      end
      squish_validate { |result, text:| result.regex.include?(text) ? nil : ["regex must mention #{text}"] }
      squish_fallback { |error, text:| { regex: "fallback-#{text}-#{error.class.name.split('::').last}" } }

      def self.to_s = "Proposer"

      def initialize(tenant: "acme") = @tenant = tenant

      attr_reader :tenant

      def call(text:) = result(regex: text)
    end
  end

  describe ".validate" do
    it "returns the messages squish_validate rejects a reply with" do
      expect(Squishling::Testing.validate(klass, { "regex" => "xyz" }, text: "abc")).to eq(["regex must mention abc"])
    end

    it "returns the schema's messages first, and [] for an acceptable reply" do
      expect(squishling_validate(klass, { "regex" => 3 }, text: "abc").first).to include("regex")
      expect(squishling_validate(klass, "not json", text: "abc")).to match([/not valid JSON/])
      expect(squishling_validate(klass, { "regex" => "abc.*" }, text: "abc")).to eq([])
    end

    it "takes positional arguments as args: and a receiver for constructors with arguments" do
      klass.squish_validate { |result, text:, **| result.regex == tenant + text ? nil : ["wrong"] }
      receiver = klass.new(tenant: "t-")

      expect(squishling_validate(klass, { "regex" => "t-abc" }, receiver:, text: "abc")).to eq([])
    end
  end

  describe ".fallback_for" do
    it "runs squish_fallback and types the result" do
      result = Squishling::Testing.fallback_for(klass, Squishling::LLMError.new("x"), text: "abc")

      expect(result.regex).to eq("fallback-abc-LLMError")
      expect(result.squished?).to be(false)
    end

    it "is available as a test helper" do
      expect(squishling_fallback_for(klass, StandardError.new("x"), text: "q").regex).to eq("fallback-q-StandardError")
    end

    it "needs a squish_fallback" do
      bare = Class.new do
        include Squishling

        output_schema { string :a }
      end

      expect { Squishling::Testing.fallback_for(bare, StandardError.new) }
        .to raise_error(Squishling::Testing::SetupError, /no squish_fallback/)
    end
  end

  describe ".preview" do
    it "shows the first request without making it" do
      forbid_provider_calls!
      preview = squishling_preview(klass, text: "abc")

      expect(preview[:system_prompt]).to start_with("Propose a regex.\n\nKeep it short.")
      expect(JSON.parse(preview[:user_message])).to eq("arguments" => { "text" => "abc" },
        "context" => { "tenant" => "acme" })
      expect(preview[:output_schema]["properties"]).to include("regex")
      expect(preview[:step]).to have_attributes(model: "a", params: { temperature: 0 })
    end

    it "does not advance the rotation" do
      first = squishling_preview(klass, text: "abc")[:step].model
      again = squishling_preview(klass, text: "abc")[:step].model
      fake = fake_squishling { |llm| llm.step(:any).reply({ "regex" => "abc" }) }
      klass.squish_when { true }
      klass.call(text: "abc")

      expect([first, again]).to eq(%w[a a])
      expect(fake.models).to eq(["a"])
    end
  end
end
