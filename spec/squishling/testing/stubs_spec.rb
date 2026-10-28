# frozen_string_literal: true

require "squishling/testing"

RSpec.describe Squishling::Testing::Stubs do
  include Squishling::Testing::RSpec

  let(:klass) do
    Class.new do
      include Squishling

      purpose "Propose a regex."
      output_schema do
        string :regex
        integer :score
      end

      def self.to_s = "Proposer"
    end
  end

  describe ".result" do
    it "makes the class return a real typed result" do
      stub_squishling_result(klass, regex: "Run.*", score: 3)
      result = klass.call(text: "x")

      expect(result.regex).to eq("Run.*")
      expect(result.squished?).to be(true)
      expect(result).to be_a(Squishling::Result::Instance)
      expect(klass.new.call(text: "y")).to equal(result)
    end

    it "stands in for a Ruby-path result with squished: false" do
      stub_squishling_result(klass, { regex: "x", score: 1 }, squished: false)

      expect(klass.call.squished?).to be(false)
    end

    it "validates the attributes against the schema, so the stand-in can't drift" do
      expect { stub_squishling_result(klass, regex: "x", score: "high") }
        .to raise_error(Squishling::Testing::SetupError, /Proposer#call: the stubbed result doesn't match/)
      expect { stub_squishling_result(klass, regex: "x") }.to raise_error(Squishling::Testing::SetupError, /score/)
    end

    it "needs an output_schema" do
      bare = Class.new { include Squishling }

      expect { Squishling::Testing.stub_result(bare, a: 1) }.to raise_error(Squishling::Testing::SetupError)
    end

    it "lasts for the block when given one, then the real method comes back" do
      klass.define_method(:call) { |**| result(regex: "real", score: 0) }
      stub_squishling_result(klass, regex: "stubbed", score: 1) do
        expect(klass.call.regex).to eq("stubbed")
      end

      expect(klass.call.regex).to eq("real")
    end

    it "is cleared by reset!, and the real method comes back" do
      klass.define_method(:call) { |**| result(regex: "real", score: 0) }
      stub_squishling_result(klass, regex: "stubbed", score: 1)
      Squishling::Testing.reset!

      expect(klass.call.regex).to eq("real")
    end

    it "stubs another squished method by name" do
      klass.squish(:triage, purpose: "Triage.") { string :team }
      stub_squishling_result(klass, { team: "api" }, method: :triage)

      expect(klass.new.triage.team).to eq("api")
    end
  end

  describe ".error" do
    it "raises an InvalidOutputError with realistic attributes" do
      stub_squishling_error(klass, :invalid_output, errors: ["score is out of range"], raw: "{}", attempts: 2,
        models: %w[flash pro])

      expect { klass.call }.to raise_error(Squishling::InvalidOutputError) { |error|
        expect(error).to have_attributes(errors: ["score is out of range"], raw: "{}", attempts: 2,
          models: %w[flash pro])
      }
    end

    it "raises an LLMError and a ConfigurationError naming the method" do
      stub_squishling_error(klass, :llm_error)
      expect { klass.call }.to raise_error(Squishling::LLMError, /Proposer#call/)

      stub_squishling_error(klass, :configuration, message: "no key")
      expect { klass.call }.to raise_error(Squishling::ConfigurationError, /no key/)
    end

    it "raises a DisagreementError with typed candidates" do
      stub_squishling_error(klass, :disagreement, candidates: [{ regex: "a", score: 1 }, { regex: "b", score: 2 }],
        verdict: :neither, reason: "unsure")

      expect { klass.call }.to raise_error(Squishling::DisagreementError) { |error|
        expect(error.candidates.map(&:regex)).to eq(%w[a b])
        expect(error).to have_attributes(verdict: :neither, reason: "unsure")
      }
    end

    it "rejects an unknown kind" do
      expect { stub_squishling_error(klass, :gremlins) }.to raise_error(ArgumentError, /unknown error/)
    end
  end

  describe "after a stub is gone" do
    it "still names the arguments by the real method's parameters" do
      klass.define_method(:call) { |text, limit: 3| result(regex: text * limit, score: 1) }
      klass.squish_when { true }
      stub_squishling_result(klass, regex: "x", score: 1)
      Squishling::Testing.reset!
      fake = fake_squishling { |llm| llm.step(:any).reply({ "regex" => "r", "score" => 1 }) }

      klass.call("hello", limit: 2)

      expect(fake.arguments).to eq({ "text" => "hello", "limit" => 2 })
      expect(squishling_preview(klass, args: ["hi"])[:user_message]).to include('"text":"hi"')
    end

    it "does not reach a subclass, which keeps its own behavior" do
      stub_squishling_result(klass, regex: "x", score: 1)
      child = Class.new(klass) { def self.to_s = "Child" }
      forbid_provider_calls!

      expect { child.call(text: "y") }.to raise_error(Squishling::Testing::ProviderCallError, /Child#call/)
    end
  end

  describe "nested block stubs" do
    it "restores the outer stub when the inner block ends" do
      stub_squishling_result(klass, regex: "outer", score: 1) do
        stub_squishling_result(klass, regex: "inner", score: 2) { expect(klass.call.regex).to eq("inner") }

        expect(klass.call.regex).to eq("outer")
      end
    end
  end

  describe "a mistyped option" do
    it "fails when the error is stubbed, not in the code under test" do
      expect { stub_squishling_error(klass, :llm_error, mesage: "x") }.to raise_error(ArgumentError, /mesage/)
      expect { stub_squishling_error(klass, :disagreement) }.to raise_error(ArgumentError, /candidates/)
    end
  end
end
