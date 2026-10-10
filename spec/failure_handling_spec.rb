# frozen_string_literal: true

RSpec.describe "Squishling failure handling" do
  let(:klass) do
    Class.new do
      include Squishling

      squishling escalation: [{ model: "test-model", attempts: 2 }]
      purpose "Classify."
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

    it "rejects a number JSON can't represent, as the deterministic path does" do
      klass.output_schema { number :score }
      chats = stub_llm('{"score": 1e400}', { "score" => 2 })

      expect(klass.call(text: "x").score).to eq(2)
      expect(chats.first.messages.last).to include("value JSON can't represent")
    end

    it "rejects a string that isn't valid UTF-8, which can't be serialized again" do
      chats = stub_llm(%({"label": "x\xFFy"}), { "label" => "ok" })

      expect(klass.call(text: "x").label).to eq("ok")
      expect(chats.first.messages.last).to include("value JSON can't represent")
    end

    it "caps the errors fed back to the model and logged for a badly invalid output" do
      klass.output_schema { array :scores, of: :integer }
      chats = stub_llm({ "scores" => Array.new(500, "x") }, { "scores" => [1] })

      expect(klass.call(text: "x").scores).to eq([1])
      feedback = chats.first.messages.last
      expect(feedback.lines.count { |line| line.start_with?("- ") }).to eq(21)
      expect(feedback).to include("and 480 more errors")
    end

    describe "unrepresentable output followed by a new escalation step" do
      let(:two_steps) do
        Class.new do
          include Squishling

          squishling escalation: %w[model-a model-b]
          purpose "Classify."
          output_schema do
            string :label
            number :score
          end
        end
      end

      it "forwards a placeholder, not a crash, when a Hash response held Infinity" do
        chats = stub_llm({ "label" => "x", "score" => Float::INFINITY }, { "label" => "ok", "score" => 1 })

        expect(two_steps.call(text: "x").label).to eq("ok")
        expect(chats.last.messages.first)
          .to include("A previous attempt at this request returned:\n(a response JSON can't represent)")
      end

      it "forwards a scrubbed string when a response had invalid UTF-8" do
        chats = stub_llm(%({"label": "x\xFFy", "score": 1}), { "label" => "ok", "score" => 1 })

        expect(two_steps.call(text: "x").label).to eq("ok")
        expect(chats.last.messages.first).to include("A previous attempt at this request returned")
        expect(chats.last.messages.first).to be_valid_encoding
      end

      it "forwards a binary-tagged response as valid text, even beside non-ASCII input" do
        chats = stub_llm(%({"label": "x\xFFy", "score": 1}).b, { "label" => "ok", "score" => 1 })

        expect(two_steps.call(text: "café").label).to eq("ok")
        expect(chats.last.messages.first).to be_valid_encoding
        expect(chats.last.messages.first).to include("café")
      end

      it "raises InvalidOutputError, not a serialization error, when the last step also fails" do
        stub_llm({ "label" => "x", "score" => Float::INFINITY }, { "label" => "y", "score" => Float::NAN })

        expect { two_steps.call(text: "x") }.to raise_error(Squishling::InvalidOutputError) do |e|
          expect(e.models).to eq(%w[model-a model-b])
        end
      end
    end

    describe "model output in messages and logs" do
      let(:log) { StringIO.new }

      before { Squishling.configure { |c| c.logger = Logger.new(log) } }

      it "keeps unparseable output out of the error, the log, and the retry message" do
        chats = stub_llm('{"label": SECRET_TOKEN oops}', '{"label": SECRET_TOKEN oops}')

        expect { klass.call(text: "x") }.to raise_error(Squishling::InvalidOutputError, /not valid JSON/) do |e|
          expect(e.message).not_to include("SECRET_TOKEN")
          expect(e.errors.join).not_to include("SECRET_TOKEN")
          expect(e.raw).to include("SECRET_TOKEN")
        end
        expect(log.string).to include("not valid JSON")
        expect(log.string).not_to include("SECRET_TOKEN")
        expect(chats.first.messages.last).not_to include("SECRET_TOKEN")
      end

      it "reports where parsing failed" do
        stub_llm('{"label": SECRET_TOKEN oops}', '{"label": SECRET_TOKEN oops}')

        expect { klass.call(text: "x") }.to raise_error(Squishling::InvalidOutputError, /at line 1 column \d+/)
      end

      it "reports a failure without a position" do
        allow(JSON).to receive(:parse).and_call_original
        allow(JSON).to receive(:parse).with("SECRET_TOKEN")
          .and_raise(JSON::ParserError, "unexpected token at 'SECRET_TOKEN'")
        stub_llm("SECRET_TOKEN", "SECRET_TOKEN")

        expect { klass.call(text: "x") }
          .to raise_error(Squishling::InvalidOutputError, "LLM output was invalid after 2 attempts: " \
                                                          "response was not valid JSON")
      end

      it "doesn't echo rejected values in schema errors" do
        klass.output_schema { string :label, enum: %w[a b] }
        stub_llm({ "label" => "SECRET_TOKEN" }, { "label" => "SECRET_TOKEN" })

        expect { klass.call(text: "x") }.to raise_error(Squishling::InvalidOutputError, /not one of/) do |e|
          expect(e.message).not_to include("SECRET_TOKEN")
        end
        expect(log.string).not_to include("SECRET_TOKEN")
      end
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

    it "makes a single attempt for a single model" do
      klass.squishling(model: "test-model")
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
    before { klass.squishling(model: "test-model") }

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
      klass.squishling(escalation: [{ model: "test-model", attempts: 2 }])
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

        squishling escalation: [{ model: "test-model", attempts: 2 }]
        purpose "Classify."
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

    it "uses the fallback when the LLM call fails on every model" do
      stub_llm(RubyLLM::RateLimitError.new("slow down"), RubyLLM::RateLimitError.new("still slow"))
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

    it "rejects a fallback return that isn't the schema's object" do
      stub_llm(nil, nil)

      [nil, "fallback", [1], Object.new].each do |value|
        klass.squish_fallback { |_error, **| value }

        expect { klass.call(text: "hi") }.to raise_error(Squishling::InvalidOutputError, /Deterministic/)
        stub_llm(nil, nil)
      end
    end

    it "re-validates a fallback return built from a different schema" do
      other = Class.new do
        include Squishling

        purpose "x"
        output_schema { string :label }

        def call = { label: "other" }
      end
      mismatched = Class.new do
        include Squishling

        purpose "x"
        output_schema { integer :label }

        def call = { label: 1 }
      end
      stub_llm(nil, nil)

      klass.squish_fallback { |_error, **| other.call }
      converted = klass.call(text: "hi")
      expect(converted.label).to eq("other")
      expect(converted.class).not_to equal(other.call.class)

      stub_llm(nil, nil)
      klass.squish_fallback { |_error, **| mismatched.call }
      expect { klass.call(text: "hi") }.to raise_error(Squishling::InvalidOutputError, /Deterministic/)
    end

    it "lets a fallback post-process a plain value from calling the method itself" do
      klass.squish_when { |**| true }
      klass.squish_fallback { |_error, **inputs| { label: call(**inputs) || "default" } }
      klass.define_method(:call) { |text:| text == "skip" ? nil : text }
      stub_llm(nil, nil)

      expect(klass.call(text: "skip").label).to eq("default")
    end

    it "lets squish_when consume a plain value from calling the method itself" do
      klass.squish_when { |**inputs| call(**inputs).nil? }
      klass.define_method(:call) { |text:| text == "skip" ? nil : { label: text } }
      stub_llm(label: "from llm")

      expect(klass.call(text: "skip").label).to eq("from llm")
      expect(klass.call(text: "keep").label).to eq("keep")
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
