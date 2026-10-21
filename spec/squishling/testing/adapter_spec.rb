# frozen_string_literal: true

require "squishling/testing"

RSpec.describe Squishling::Testing::Adapter do
  include Squishling::Testing::RSpec

  let(:klass) do
    Class.new do
      include Squishling

      squishling escalation: [{ model: "flash", attempts: 2, provider: :vertexai }, "pro"], params: { temperature: 0 }
      purpose "Rate the ticket."
      squish_context :tenant
      output_schema do
        string :label
        integer :score, minimum: 1, maximum: 5
      end

      def self.to_s = "Rater"

      def tenant = "acme"
    end
  end

  let(:answer) { { "label" => "ok", "score" => 3 } }

  describe "scripted replies" do
    it "answers in order and repeats the last one" do
      fake = fake_squishling { |llm| llm.step(:any).reply({ "label" => "a", "score" => 1 }, answer) }

      expect(klass.call(text: "x").label).to eq("a")
      expect(klass.call(text: "x").label).to eq("ok")
      expect(klass.call(text: "x").label).to eq("ok")
      expect(fake.requests.size).to eq(3)
    end

    it "runs out of answers when the rule is once" do
      fake_squishling { |llm| llm.step(:any).reply(answer).once }

      klass.call(text: "x")
      expect { klass.call(text: "x") }.to raise_error(Squishling::Testing::UnscriptedRequestError, /no answers left/)
    end

    it "takes raw text, fenced JSON, and an empty response as the model's output" do
      fake_squishling do |llm|
        llm.step(:any).reply("not json", "```json\n#{JSON.generate(answer)}\n```")
      end

      expect(klass.call(text: "x").score).to eq(3)
    end

    it "treats nil as an empty response and reports it as invalid output" do
      fake_squishling { |llm| llm.step(:any).reply(nil) }

      expect { klass.call(text: "x") }
        .to raise_error(Squishling::InvalidOutputError, /response was empty/) { |error| expect(error.attempts).to eq(3) }
    end

    it "raises an Exception class reply, as a new instance" do
      fake_squishling { |llm| llm.step(:any).reply(KeyError) }

      expect { klass.call(text: "x") }.to raise_error(KeyError)
    end

    it "raises an Exception reply as is" do
      fake_squishling { |llm| llm.step(:any).reply(ArgumentError.new("boom")) }

      expect { klass.call(text: "x") }.to raise_error(ArgumentError, "boom")
    end

    it "fakes a model id and token usage" do
      reply = Squishling::Testing::Reply.new(answer, model: "flash-001", usage: { input_tokens: 10, output_tokens: 4 })
      fake_squishling { |llm| llm.step(:any).reply(reply) }
      capture = Squishling::Testing.with_squawk { klass.call(text: "x") }

      expect(capture.calls.first.metadata).to include(model: "flash-001", usage: { input_tokens: 10, output_tokens: 4 })
    end
  end

  describe "provider failures by intent" do
    {
      rate_limit: [Squishling::LLMError, /rate limited \(HTTP 429\)/],
      server_error: [Squishling::LLMError, /server error \(HTTP 500\)/],
      timeout: [Squishling::LLMError, /timed out/],
      overloaded: [Squishling::LLMError, /overloaded/],
      context_length: [Squishling::LLMError, /context length/],
      bad_request: [Squishling::ConfigurationError, /bad request \(HTTP 400\)/],
      unauthorized: [Squishling::ConfigurationError, /unauthorized \(HTTP 401\)/],
      forbidden: [Squishling::ConfigurationError, /forbidden/]
    }.each do |intent, (error, message)|
      it "raises #{error} for #{intent}" do
        fake_squishling { |llm| llm.step(:any).fail(intent) }

        expect { klass.call(text: "x") }.to raise_error(error, message)
      end
    end

    it "moves on to the next attempt after an LLMError, in a fresh conversation" do
      fake = fake_squishling { |llm| llm.step(:any).fail(:rate_limit).reply(answer) }

      expect(klass.call(text: "x").score).to eq(3)
      expect(fake.requests.map(&:conversation)).to eq([0, 1])
      expect(fake.requests.map(&:model)).to eq(%w[flash flash])
    end

    it "rejects an unknown intent" do
      expect do
        fake_squishling do |llm|
          llm.step(:any).fail(:gremlins)
        end
      end.to raise_error(ArgumentError, /unknown failure/)
    end

    it "does not let squish_fallback absorb a ConfigurationError" do
      klass.squish_fallback { |_error, **| { "label" => "fallback", "score" => 1 } }
      fake_squishling { |llm| llm.step(:any).fail(:unauthorized) }

      expect { klass.call(text: "x") }.to raise_error(Squishling::ConfigurationError)
    end
  end

  describe "per-step scripts" do
    let(:bad) { { "label" => "x", "score" => 99 } }

    it "answers each model from its own script" do
      fake = fake_squishling do |llm|
        llm.step("flash").reply(bad)
        llm.step("pro").reply(answer)
      end

      expect(klass.call(text: "x").score).to eq(3)
      expect(fake.models).to eq(%w[flash flash pro])
      expect(fake.requests.map(&:attempt)).to eq([1, 2, 3])
    end

    it "matches a provider and an attempt" do
      fake = fake_squishling do |llm|
        llm.step(provider: :vertexai, attempt: 1).reply(bad)
        llm.step(provider: :vertexai, attempt: 2).reply(bad)
        llm.step(:any).reply(answer)
      end

      expect(klass.call(text: "x").score).to eq(3)
      expect(fake.requests.map(&:provider)).to eq([:vertexai, :vertexai, nil])
    end

    it "lets a narrower rule win over a broader one declared earlier" do
      klass.squishling escalation: [{ model: "m1", attempts: 2 }]
      fake = fake_squishling do |llm|
        llm.step("m1").reply({ "label" => "broad", "score" => 99 })
        llm.step("m1", attempt: 2).reply({ "label" => "narrow", "score" => 2 })
      end

      expect(klass.call(text: "x").label).to eq("narrow")
      expect(fake.requests.map(&:attempt)).to eq([1, 2])
    end

    it "prefers a rule naming a model and a provider over one naming the model" do
      fake_squishling do |llm|
        llm.step("flash").reply({ "label" => "model", "score" => 1 })
        llm.step("flash", provider: :vertexai).reply({ "label" => "both", "score" => 1 })
      end

      expect(klass.call(text: "x").label).to eq("both")
    end

    it "tells a retry (same conversation) from an escalation (a new one)" do
      fake = fake_squishling do |llm|
        llm.step("flash").reply(bad)
        llm.step("pro").reply(answer)
      end
      klass.call(text: "x")

      expect(fake.conversations.map { |chat| chat.map(&:model) }).to eq([%w[flash flash], %w[pro]])
      retry_request = fake.requests[1]
      expect(retry_request.errors).to include(a_string_matching(/score/))
      expect(fake.requests[2].errors).to include(a_string_matching(/score/))
      expect(fake.requests[2].forwarded_rejected).to include('"score":99').or include('"score" => 99')
    end

    it "does not forward the rejected output when forward_rejected is false" do
      klass.squishling escalation: ["flash", { model: "pro", forward_rejected: false }]
      fake = fake_squishling do |llm|
        llm.step("flash").reply(bad)
        llm.step("pro").reply(answer)
      end
      klass.call(text: "x")

      expect(fake.requests.last.forwarded_rejected).to be_nil
    end

    it "follows a rotated tier by model, whichever model goes first" do
      klass.squishling escalation: [{ model: "a", priority: 1 }, { model: "b", priority: 1 }]
      fake = fake_squishling do |llm|
        llm.step("a").reply({ "label" => "from-a", "score" => 1 })
        llm.step("b").reply({ "label" => "from-b", "score" => 2 })
      end

      labels = Array.new(4) { klass.call(text: "x").label }

      expect(labels.uniq.sort).to eq(%w[from-a from-b])
      expect(fake.models).to eq(labels.map { |label| label.delete_prefix("from-") })
    end
  end

  describe "recorded requests" do
    it "shows what left the process" do
      fake = fake_squishling { |llm| llm.step(:any).reply(answer) }
      klass.call(text: "hello")
      request = fake.requests.first

      expect(request).to have_attributes(label: "Rater#call", type: :chat, role: nil, model: "flash",
        provider: :vertexai, params: { temperature: 0 }, attempt: 1, attempts: 3, conversation: 0)
      expect(request.arguments).to eq({ "text" => "hello" })
      expect(request.context).to eq({ "tenant" => "acme" })
      expect(request.system_prompt).to start_with("Rate the ticket.")
      expect(request.output_schema["properties"]).to include("label", "score")
      expect(request.reply).to be_a(Squishling::Adapter::Response)
      expect(fake.arguments).to eq({ "text" => "hello" })
    end

    it "keeps the failed requests too" do
      fake = fake_squishling { |llm| llm.step(:any).fail(:server_error).reply(answer) }
      klass.call(text: "x")

      expect(fake.requests.map(&:failed?)).to eq([true, false])
    end
  end

  describe "unscripted requests" do
    it "raises an error naming the call, outside the Squishling taxonomy" do
      fake = fake_squishling { |llm| llm.step("other").reply(answer) }
      klass.squish_fallback { |_error, **| { "label" => "fallback", "score" => 1 } }

      expect { klass.call(text: "x") }
        .to raise_error(Squishling::Testing::UnscriptedRequestError, /Rater#call: unscripted chat request.*flash/)
      expect(fake.requests.size).to eq(1)
    end
  end

  describe "working without the observer" do
    it "still records the requests, inferring what it can" do
      adapter = described_class.new
      adapter.script.step(:any).reply(answer)
      Squishling.config.adapter = adapter

      expect(klass.call(text: "x").score).to eq(3)
      expect(adapter.requests.first.role).to be_nil
    end
  end

  describe "a request whose first message isn't the payload" do
    it "reads no arguments rather than failing" do
      expect(Squishling::Testing::Request.payload_of([{ role: :user, content: "plain text" }])).to eq({})
    end
  end
end
