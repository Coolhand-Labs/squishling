# frozen_string_literal: true

RSpec.describe "Squishling failure handling" do
  let(:klass) do
    Class.new do
      include Squishling

      instructions "Classify."
      output_schema { string :label }
    end
  end

  describe "missing or malformed LLM output" do
    it "retries an empty (nil) response, e.g. a refusal with no content" do
      chats = stub_llm(nil, { "label" => "ok" })

      expect(klass.call(text: "x").label).to eq("ok")
      expect(chats.first.messages.last).to include("response was empty")
    end

    it "treats a blank string as empty" do
      stub_llm("  \n", "")

      expect { klass.call(text: "x") }
        .to raise_error(Squishling::InvalidOutputError, /response was empty/) { |e| expect(e.attempts).to eq(2) }
    end

    it "retries truncated JSON" do
      chats = stub_llm('{"label": "o', { "label" => "ok" })

      expect(klass.call(text: "x").label).to eq("ok")
      expect(chats.first.messages.last).to include("not valid JSON")
    end

    it "parses JSON wrapped in a markdown code fence" do
      stub_llm("```json\n{\"label\": \"fenced\"}\n```")

      expect(klass.call(text: "x").label).to eq("fenced")
    end

    it "retries a refusal message returned as plain text" do
      stub_llm("I can't help with that.", { "label" => "ok" })

      expect(klass.call(text: "x").label).to eq("ok")
    end

    it "rejects a JSON root that isn't an object" do
      stub_llm('["ok"]', "[]")

      expect { klass.call(text: "x") }.to raise_error(Squishling::InvalidOutputError, /not an object/)
    end

    it "rejects extra keys, as strict mode requires" do
      stub_llm({ "label" => "ok", "extra" => 1 }, { "label" => "ok", "extra" => 1 })

      expect { klass.call(text: "x") }.to raise_error(Squishling::InvalidOutputError)
    end

    it "makes a single attempt when max_retries is 0" do
      Squishling.configure { |c| c.max_retries = 0 }
      chats = stub_llm(nil)

      expect { klass.call(text: "x") }
        .to raise_error(Squishling::InvalidOutputError) { |e| expect(e.attempts).to eq(1) }
      expect(chats.first.messages.size).to eq(1)
    end

    it "reports the last raw output and attempt count" do
      stub_llm({ "label" => 1 }, { "label" => 2 })

      expect { klass.call(text: "x") }.to raise_error(Squishling::InvalidOutputError, /after 2 attempts/) do |e|
        expect(e.raw).to eq("label" => 2)
        expect(e.errors).not_to be_empty
      end
    end
  end

  describe "LLM call failures" do
    {
      "rate limit" => RubyLLM::RateLimitError.new("slow down"),
      "server error" => RubyLLM::ServerError.new("boom"),
      "overload" => RubyLLM::OverloadedError.new("busy"),
      "timeout" => Faraday::TimeoutError.new("timed out"),
      "connection failure" => Faraday::ConnectionFailed.new("refused")
    }.each do |label, error|
      it "wraps a #{label} in LLMError, keeping the cause" do
        stub_llm(error)

        expect { klass.call(text: "x") }.to raise_error(Squishling::LLMError, /#{error.class}/) do |e|
          expect(e.cause).to equal(error)
          expect(e).to be_a(Squishling::Error)
        end
      end
    end

    it "wraps a failure on a retry request too" do
      stub_llm({ "label" => 1 }, RubyLLM::ServiceUnavailableError.new("down"))

      expect { klass.call(text: "x") }.to raise_error(Squishling::LLMError, /ServiceUnavailable/)
    end

    it "treats bad credentials as a configuration error" do
      stub_llm(RubyLLM::UnauthorizedError.new("bad key"))

      expect { klass.call(text: "x") }.to raise_error(Squishling::ConfigurationError, /bad key/)
    end

    it "treats an unknown model as a configuration error" do
      allow(RubyLLM).to receive(:chat).and_raise(RubyLLM::ModelNotFoundError, "Unknown model: nope")

      expect { klass.call(text: "x") }.to raise_error(Squishling::ConfigurationError, /Unknown model/)
    end
  end

  describe "squish_fallback" do
    let(:klass) do
      Class.new do
        include Squishling

        instructions "Classify."
        output_schema { string :label }
        squish_fallback do |error, text:|
          @seen = [error.class, text]
          { label: "fallback" }
        end
        attr_reader :seen
      end
    end

    it "uses the fallback when the output is invalid after retries" do
      stub_llm(nil, nil)
      instance = klass.new

      result = instance.call(text: "hi")

      expect(result.label).to eq("fallback")
      expect(result.squished?).to be(false)
      expect(instance.seen).to eq([Squishling::InvalidOutputError, "hi"])
    end

    it "uses the fallback when the LLM call fails" do
      stub_llm(RubyLLM::RateLimitError.new("slow down"))
      instance = klass.new

      expect(instance.call(text: "hi").label).to eq("fallback")
      expect(instance.seen.first).to eq(Squishling::LLMError)
    end

    it "is not used for configuration errors" do
      stub_llm(RubyLLM::UnauthorizedError.new("bad key"))

      expect { klass.call(text: "hi") }.to raise_error(Squishling::ConfigurationError)
    end

    it "validates the fallback's return value against the schema" do
      klass.squish_fallback { |_error, **| { label: 1 } }
      stub_llm(nil, nil)

      expect { klass.call(text: "hi") }.to raise_error(Squishling::InvalidOutputError, /Deterministic/)
    end

    it "can re-raise to propagate the error" do
      klass.squish_fallback { |error, **| raise error }
      stub_llm(nil, nil)

      expect { klass.call(text: "hi") }.to raise_error(Squishling::InvalidOutputError)
    end

    it "runs the Ruby implementation when the fallback calls the method itself" do
      klass.squish_when { |text:| text.length > 5 }
      klass.squish_fallback { |_error, **inputs| call(**inputs) }
      klass.define_method(:call) { |text:| { label: "ruby #{text}" } }
      chats = stub_llm(nil, nil)

      expect(klass.call(text: "too long").label).to eq("ruby too long")
      expect(chats.size).to eq(1)
    end

    it "can build the result with result(...)" do
      klass.squish_fallback { |_error, text:| result(label: text.upcase) }
      stub_llm(nil, nil)

      expect(klass.call(text: "hi").label).to eq("HI")
    end

    it "accepts a per-method fallback that overrides the class one" do
      klass.squish(:tag, fallback: ->(_error, **) { { label: "method" } }) { string :label }
      stub_llm(nil, nil)

      expect(klass.new.tag(text: "hi").label).to eq("method")
    end

    it "is inherited by subclasses" do
      stub_llm(nil, nil)

      expect(Class.new(klass).call(text: "hi").label).to eq("fallback")
    end

    it "does not run when the LLM succeeds" do
      stub_llm({ "label" => "llm" })
      instance = klass.new

      expect(instance.call(text: "hi").label).to eq("llm")
      expect(instance.seen).to be_nil
    end
  end
end
