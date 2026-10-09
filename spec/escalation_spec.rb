# frozen_string_literal: true

require "logger"
require "stringio"

RSpec.describe "Squishling model escalation" do
  let(:klass) do
    Class.new do
      include Squishling

      squishling escalation: [{ model: "claude-haiku-4-5", attempts: 2 }, "claude-sonnet-5-5"]
      purpose "Classify."
      output_schema { string :label }
    end
  end

  describe "walking the path" do
    it "retries the same model in one conversation, then escalates to a fresh chat" do
      chats = stub_llm({ "label" => 1 }, nil, { "label" => "ok" })

      expect(klass.call(text: "x").label).to eq("ok")
      expect(chats.map(&:model)).to eq(%w[claude-haiku-4-5 claude-sonnet-5-5])
      expect(chats.first.messages.size).to eq(2)
      expect(chats.first.messages.last).to include("not a string")

      escalated = chats.last.messages
      expect(escalated.size).to eq(1)
      expect(escalated.first).to start_with(JSON.generate(arguments: { text: "x" }))
      expect(escalated.first).to include("(an empty response)", "response was empty")
      expect(chats.last.schema).to eq(chats.first.schema)
      expect(chats.last.instructions).to eq(chats.first.instructions)
    end

    it "stops at the first valid output" do
      chats = stub_llm({ "label" => "ok" })

      expect(klass.call(text: "x").label).to eq("ok")
      expect(chats.size).to eq(1)
    end

    it "raises InvalidOutputError with every model tried once the path is exhausted" do
      stub_llm({ "label" => 1 }, { "label" => 2 }, { "label" => 3 })

      expect { klass.call(text: "x") }.to raise_error(Squishling::InvalidOutputError, /after 3 attempts/) do |e|
        expect(e.attempts).to eq(3)
        expect(e.models).to eq(%w[claude-haiku-4-5 claude-haiku-4-5 claude-sonnet-5-5])
        expect(e.raw).to eq("label" => 3)
      end
    end

    it "makes a single attempt for a single model" do
      klass.squishling(model: "claude-haiku-4-5")
      chats = stub_llm({ "label" => 1 }, { "label" => "unused" })

      expect { klass.call(text: "x") }
        .to raise_error(Squishling::InvalidOutputError) { |e| expect(e.models).to eq(["claude-haiku-4-5"]) }
      expect(chats.size).to eq(1)
    end

    it "uses squish_fallback after the path is exhausted" do
      klass.squish_fallback { |error, **| { label: "fallback after #{error.attempts}" } }
      stub_llm(nil, nil, nil)

      expect(klass.call(text: "x").label).to eq("fallback after 3")
    end

    it "logs each escalation" do
      log = StringIO.new
      Squishling.configure { |c| c.logger = Logger.new(log) }
      stub_llm(nil, nil, { "label" => "ok" })

      klass.call(text: "x")

      expect(log.string).to include("attempt 1 of 3 (claude-haiku-4-5) failed, retrying")
      expect(log.string).to include("attempt 2 of 3 (claude-haiku-4-5) failed, escalating to claude-sonnet-5-5")
    end
  end

  describe "LLM call failures" do
    it "escalates to the next model in a fresh chat" do
      klass.squishling(escalation: %w[claude-haiku-4-5 claude-sonnet-5-5])
      chats = stub_llm(RubyLLM::OverloadedError.new("busy"), { "label" => "ok" })

      expect(klass.call(text: "x").label).to eq("ok")
      expect(chats.map(&:model)).to eq(%w[claude-haiku-4-5 claude-sonnet-5-5])
      expect(chats.last.messages).to eq([JSON.generate(arguments: { text: "x" })])
    end

    it "starts a fresh chat even when retrying the same model" do
      chats = stub_llm(RubyLLM::RateLimitError.new("slow"), { "label" => "ok" })

      expect(klass.call(text: "x").label).to eq("ok")
      expect(chats.map(&:model)).to eq(%w[claude-haiku-4-5 claude-haiku-4-5])
    end

    it "tells the next model about an earlier rejected output" do
      chats = stub_llm({ "label" => 1 }, RubyLLM::ServerError.new("boom"), { "label" => "ok" })

      expect(klass.call(text: "x").label).to eq("ok")
      expect(chats.last.messages.first).to include('{"label":1}', "not a string")
    end

    it "starts a step from the original input alone with forward_rejected: false" do
      klass.squishling(escalation: ["a", { model: "b", forward_rejected: false }, "c"])
      chats = stub_llm({ "label" => 1 }, { "label" => 2 }, { "label" => "ok" })

      expect(klass.call(text: "x").label).to eq("ok")
      input = JSON.generate(arguments: { text: "x" })
      expect(chats[1].messages).to eq([input])
      expect(chats[2].messages.first).to include('{"label":2}', "not a string")
    end

    it "still retries a forward_rejected: false step in one conversation" do
      klass.squishling(escalation: [{ model: "a", attempts: 2, forward_rejected: false }])
      chats = stub_llm({ "label" => 1 }, { "label" => "ok" })

      expect(klass.call(text: "x").label).to eq("ok")
      expect(chats.size).to eq(1)
      expect(chats.first.messages.last).to include("not a string")
    end

    it "starts a forward_rejected: false step from the input alone after a provider error" do
      klass.squishling(escalation: ["a", "b", { model: "c", forward_rejected: false }])
      chats = stub_llm({ "label" => 1 }, RubyLLM::ServerError.new("boom"), { "label" => "ok" })

      expect(klass.call(text: "x").label).to eq("ok")
      expect(chats.last.messages).to eq([JSON.generate(arguments: { text: "x" })])
    end

    it "treats steps that differ only in forward_rejected as different steps" do
      klass.squishling(escalation: ["a", { model: "a", forward_rejected: false }])
      chats = stub_llm({ "label" => 1 }, { "label" => "ok" })

      klass.call(text: "x")
      expect(chats.size).to eq(2)
      expect(chats.last.messages).to eq([JSON.generate(arguments: { text: "x" })])
    end

    it "takes forward_rejected: from default_escalation" do
      Squishling.config.default_escalation = ["a", { model: "b", forward_rejected: false }]
      plain = Class.new do
        include Squishling

        squishling
        purpose "Classify."
        output_schema { string :label }
      end
      chats = stub_llm({ "label" => 1 }, { "label" => "ok" })

      plain.call(text: "x")
      expect(chats.last.messages).to eq([JSON.generate(arguments: { text: "x" })])
    end

    it "caps the rejected output it forwards" do
      long = "x" * (Squishling::Invoker::MAX_FORWARDED_CHARS + 50)
      chats = stub_llm(long, { "label" => "ok" })
      klass.squishling(escalation: %w[a b])

      expect(klass.call(text: "x").label).to eq("ok")
      forwarded = chats.last.messages.first
      expect(forwarded).to include("x" * Squishling::Invoker::MAX_FORWARDED_CHARS, "[truncated, 50 more characters]")
      expect(forwarded).not_to include("x" * (Squishling::Invoker::MAX_FORWARDED_CHARS + 1))
    end

    it "forwards a rejected output under the cap untouched" do
      chats = stub_llm({ "label" => 1 }, { "label" => "ok" })
      klass.squishling(escalation: %w[a b])

      klass.call(text: "x")
      expect(chats.last.messages.first).to include('{"label":1}')
      expect(chats.last.messages.first).not_to include("truncated")
    end

    it "raises LLMError with its cause when the last model fails" do
      error = RubyLLM::ServerError.new("boom")
      stub_llm(nil, nil, error)

      expect { klass.call(text: "x") }.to raise_error(Squishling::LLMError, /boom/) { |e| expect(e.cause).to equal(error) }
    end

    it "raises LLMError, not InvalidOutputError, when the last step fails after an earlier step's invalid output" do
      error = RubyLLM::ServerError.new("overloaded")
      chats = stub_llm({ "label" => 1 }, { "label" => 2 }, error)

      expect { klass.call(text: "x") }
        .to raise_error(Squishling::LLMError, /overloaded/) { |e| expect(e.cause).to equal(error) }
      expect(chats.map(&:model)).to eq(%w[claude-haiku-4-5 claude-sonnet-5-5])
      expect(chats.last.messages.size).to eq(1)
      expect(chats.last.messages.first).to include('{"label":2}', "not a string")
    end

    it "starts a fresh chat after a mid-path LLMError and still reports the final LLMError" do
      klass.squishling(escalation: [{ model: "claude-haiku-4-5", attempts: 3 }])
      first = RubyLLM::RateLimitError.new("slow down")
      last = RubyLLM::ServerError.new("boom")
      chats = stub_llm({ "label" => 1 }, first, last)

      expect { klass.call(text: "x") }
        .to raise_error(Squishling::LLMError, /boom/) { |e| expect(e.cause).to equal(last) }
      expect(chats.map { |chat| chat.messages.size }).to eq([2, 1])
      expect(chats.last.messages.first).to include('{"label":1}', "not a string")
    end

    it "hands the final LLMError to squish_fallback instead of raising" do
      klass.squish_fallback { |error, **| { label: error.class.name } }
      stub_llm({ "label" => 1 }, { "label" => 2 }, RubyLLM::ServerError.new("overloaded"))

      result = klass.call(text: "x")

      expect(result.label).to eq("Squishling::LLMError")
      expect(result).not_to be_squished
    end

    it "never escalates a configuration error" do
      chats = stub_llm(RubyLLM::UnauthorizedError.new("bad key"), { "label" => "ok" })

      expect { klass.call(text: "x") }.to raise_error(Squishling::ConfigurationError, /bad key/)
      expect(chats.size).to eq(1)
    end

    it "names the failing step's params when the provider rejects a later step" do
      klass.squishling(escalation: ["claude-haiku-4-5", { model: "gpt-unknown", params: { temperature: 0.1 } }])
      stub_llm(nil, RubyLLM::BadRequestError.new("unsupported temperature"))

      expect { klass.call(text: "x") }.to raise_error(Squishling::ConfigurationError, /temperature.*0\.1/)
    end

    it "never escalates a request the provider rejects" do
      chats = stub_llm(RubyLLM::BadRequestError.new("unsupported temperature"), { "label" => "ok" })

      expect { klass.call(text: "x") }.to raise_error(Squishling::ConfigurationError, /rejected the request/)
      expect(chats.size).to eq(1)
    end
  end

  describe "declaring the order" do
    it "repeats a step for its attempts" do
      klass.squishling(escalation: [{ model: "a", attempts: 3 }, "b"])
      stub_llm(nil, nil, nil, nil)

      expect { klass.call(text: "x") }
        .to raise_error(Squishling::InvalidOutputError) { |e| expect(e.models).to eq(%w[a a a b]) }
    end

    it "sorts steps by an explicit order:, lowest first" do
      klass.squishling(escalation: [
        { model: "claude-opus-5-5", order: 20 },
        { model: "claude-haiku-4-5", order: 0, attempts: 2 },
        { model: "claude-sonnet-5-5", order: 10 }
      ])
      stub_llm(nil, nil, nil, nil)

      expect { klass.call(text: "x") }.to raise_error(Squishling::InvalidOutputError) do |e|
        expect(e.models).to eq(%w[claude-haiku-4-5 claude-haiku-4-5 claude-sonnet-5-5 claude-opus-5-5])
      end
    end

    it "accepts negative orders and string keys" do
      klass.squishling(escalation: [{ "model" => "b", "order" => 1 }, { "model" => "a", "order" => -1 }])
      stub_llm(nil, nil)

      expect { klass.call(text: "x") }
        .to raise_error(Squishling::InvalidOutputError) { |e| expect(e.models).to eq(%w[a b]) }
    end
  end

  describe "path resolution" do
    let(:base) do
      Class.new do
        include Squishling

        purpose "x"
        output_schema { string :value }
      end
    end

    def models_tried(klass, method = :call)
      chats = stub_llm(nil, nil, nil, nil)
      begin
        klass.new.public_send(method)
      rescue Squishling::InvalidOutputError => e
        return e.models
      end
      chats.map(&:model)
    end

    it "uses the configured default escalation" do
      Squishling.configure { |c| c.default_escalation = %w[a b] }

      expect(models_tried(base)).to eq(%w[a b])
    end

    it "makes a single attempt for a configured default model" do
      Squishling.configure { |c| c.default_model = "a" }

      expect(models_tried(base)).to eq(%w[a])
    end

    it "lets the latest of default_model and default_escalation win" do
      Squishling.configure do |c|
        c.default_escalation = %w[a b]
        c.default_model = "c"
      end
      expect(models_tried(base)).to eq(%w[c])
      expect(Squishling.config.default_escalation).to be_nil

      Squishling.configure { |c| c.default_escalation = %w[d e] }
      expect(models_tried(base)).to eq(%w[d e])
      expect(Squishling.config.default_model).to be_nil
    end

    it "prefers the class over the config, and the method over both" do
      Squishling.configure { |c| c.default_escalation = %w[a b] }
      base.squishling(escalation: %w[c d e])
      base.squish(:quick, model: "f") { string :value }
      base.squish(:deep, escalation: %w[g h]) { string :value }

      expect(models_tried(base)).to eq(%w[c d e])
      expect(models_tried(base, :quick)).to eq(%w[f])
      expect(models_tried(base, :deep)).to eq(%w[g h])
    end

    it "lets a class model override an inherited escalation, and the latest declaration win" do
      base.squishling(escalation: %w[c d])
      child = Class.new(base) { squishling model: "e" }

      expect(models_tried(Class.new(base))).to eq(%w[c d])
      expect(models_tried(child)).to eq(%w[e])

      child.squishling(escalation: %w[f g])
      expect(models_tried(child)).to eq(%w[f g])
    end

    it "applies the level's provider to steps without their own" do
      base.squishling(escalation: ["gpt-unknown", { model: "claude-opus-5-5", provider: :anthropic }],
        provider: :openai)
      chats = stub_llm(nil, { "value" => "v" })

      base.call

      expect(chats.first.options).to eq(provider: :openai, assume_model_exists: true)
      expect(chats.last.options).to include(provider: :anthropic)
    end

    it "merges step params over the class params, letting nil unset a key" do
      base.squishling(params: { temperature: 0.2, top_p: 0.9 },
        escalation: ["claude-haiku-4-5", { model: "gpt-unknown", provider: :openai,
                                           params: { temperature: nil, thinking: { effort: :high } } }])
      chats = stub_llm(nil, { "value" => "v" })

      base.call

      expect(chats.first.generation).to eq(temperature: 0.2, provider_options: { top_p: 0.9 })
      expect(chats.last.generation).to eq(thinking: { effort: :high }, provider_options: { top_p: 0.9 })
    end

    it "accepts symbols and string-keyed hashes" do
      base.squishling(escalation: [:a, { "model" => "b" }])

      expect(models_tried(base)).to eq(%w[a b])
    end
  end

  describe "invalid declarations" do
    let(:base) { Class.new { include Squishling } }

    [
      ["claude-haiku-4-5", /must be an Array of steps/],
      [[], /can't be empty/],
      [[nil], /must be a model name or a Hash/],
      [[""], /can't be blank/],
      [[{ provider: :openai }], /needs a model: name/],
      [[{ model: "a", temprature: 1 }], /unknown step option\(s\) temprature/],
      [[{ model: "a", params: { messages: [] } }], /messages can't be set through params/],
      [[{ model: "a", attempts: 0 }], /attempts: must be a positive Integer/],
      [[{ model: "a", attempts: "2" }], /attempts: must be a positive Integer/],
      [[{ model: "a", order: 1 }, "b"], /every step an order: or none \(1 of 2/],
      [[{ model: "a", order: 1 }, { model: "b", order: 1 }], /duplicate order: 1/],
      [[{ model: "a", order: 1.5 }], /order: must be an Integer/],
      [[{ model: "a", forward_rejected: "no" }], /forward_rejected: must be true or false/],
      [[{ model: "a", forward_rejected: nil }], /forward_rejected: must be true or false/]
    ].each do |escalation, message|
      it "rejects escalation #{escalation.inspect} at declaration time" do
        expect { base.squishling(escalation:) }.to raise_error(Squishling::ConfigurationError, message)
        expect { base.squish(:x, escalation:) { string :v } }.to raise_error(Squishling::ConfigurationError, message)
        expect { Squishling.config.default_escalation = escalation }
          .to raise_error(Squishling::ConfigurationError, message)
      end
    end

    it "rejects a list passed as model:" do
      error = [Squishling::ConfigurationError, /use escalation:/]
      [%w[a b], { model: "a" }].each do |model|
        expect { base.squishling(model:) }.to raise_error(*error)
        expect { base.squish(:x, model:) { string :v } }.to raise_error(*error)
        expect { Squishling.config.default_model = model }.to raise_error(*error)
      end
    end

    it "rejects model: and escalation: in the same declaration" do
      expect { base.squishling(model: "a", escalation: %w[b]) }
        .to raise_error(Squishling::ConfigurationError, /model: or escalation:, not both/)
      expect { base.squish(:x, model: "a", escalation: %w[b]) { string :v } }
        .to raise_error(Squishling::ConfigurationError, /not both/)
    end

    it "explains that max_retries was replaced by escalation attempts" do
      expect { Squishling.configure { |c| c.max_retries = 2 } }
        .to raise_error(Squishling::ConfigurationError, /default_escalation .* attempts:/)
      expect { Squishling.config.max_retries }
        .to raise_error(Squishling::ConfigurationError, /default_escalation .* attempts:/)
    end
  end
end
