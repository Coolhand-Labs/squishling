# frozen_string_literal: true

RSpec.describe Squishling::Params do
  let(:base) do
    Class.new do
      include Squishling

      purpose "Extract."
      output_schema { string :value }
    end
  end

  def generation_for(klass, method = :call)
    chats = stub_llm({ "value" => "v" })
    klass.new.public_send(method)
    chats.first.generation
  end

  describe "applying params to the chat" do
    it "sends nothing extra when no params are set" do
      expect(generation_for(base)).to eq({})
    end

    it "maps temperature and thinking to RubyLLM's setters and passes the rest through" do
      base.squishling(params: { temperature: 0.1, thinking: { effort: :low }, top_p: 0.9, max_tokens: 500 })

      expect(generation_for(base)).to eq(
        temperature: 0.1,
        thinking: { effort: :low },
        provider_options: { top_p: 0.9, max_tokens: 500 }
      )
    end

    it "maps max_output_tokens to RubyLLM's portable setter" do
      base.squishling(params: { max_output_tokens: 800 })

      expect(generation_for(base)).to eq(max_output_tokens: 800)
    end

    it "accepts thinking as true (model default), false (off), or options including display" do
      { true => true, false => false, { effort: :high, display: :omitted } => { effort: :high, display: :omitted } }
        .each do |thinking, sent|
          base.squishling(params: { thinking: })
          expect(generation_for(base)).to eq(thinking: sent)
        end
    end

    it "accepts string keys" do
      base.squishling(params: { "temperature" => 0, "thinking" => { "budget" => 1024 } })

      expect(generation_for(base)).to eq(temperature: 0, thinking: { budget: 1024 })
    end
  end

  describe "layering" do
    it "uses the configured defaults" do
      Squishling.configure { |c| c.default_params = { temperature: 0.2 } }

      expect(generation_for(base)).to eq(temperature: 0.2)
    end

    it "lets a class override individual default keys" do
      Squishling.configure { |c| c.default_params = { temperature: 0.2, top_p: 0.5 } }
      base.squishling(params: { temperature: 0 })

      expect(generation_for(base)).to eq(temperature: 0, provider_options: { top_p: 0.5 })
    end

    it "lets a method override the class, key by key" do
      base.squishling(params: { temperature: 0.1, top_p: 0.9 })
      base.squish(:creative, params: { temperature: 0.9 }) { string :value }

      expect(generation_for(base, :creative)).to eq(temperature: 0.9, provider_options: { top_p: 0.9 })
      expect(generation_for(base)).to eq(temperature: 0.1, provider_options: { top_p: 0.9 })
    end

    it "lets a nil value remove an inherited key, falling back to the provider default" do
      base.squishling(params: { temperature: 0.1 })
      base.squish(:luna, model: "gpt-unknown", provider: :openai, params: { temperature: nil }) { string :value }

      expect(generation_for(base, :luna)).to eq({})
    end

    it "merges params down the inheritance chain" do
      base.squishling(params: { temperature: 0.1, top_p: 0.9 })
      child = Class.new(base) { squishling params: { top_p: 0.5 } }

      expect(generation_for(child)).to eq(temperature: 0.1, provider_options: { top_p: 0.5 })
      expect(generation_for(base)).to eq(temperature: 0.1, provider_options: { top_p: 0.9 })
    end
  end

  describe "validation" do
    it "rejects non-hash params at every level" do
      expect { base.squishling(params: 0.1) }.to raise_error(Squishling::ConfigurationError, /must be a Hash/)
      expect { base.squish(:x, params: [:temperature]) { string :value } }
        .to raise_error(Squishling::ConfigurationError, /must be a Hash/)
      expect { Squishling.configure { |c| c.default_params = nil } }
        .to raise_error(Squishling::ConfigurationError, /default_params must be a Hash/)
    end

    it "rejects keys that would override the model, conversation, or strict output format" do
      { model: "x", "response_format" => { type: "text" }, output_config: {}, messages: [], stream: true }
        .each do |key, value|
          expect { base.squishling(params: { key => value }) }
            .to raise_error(Squishling::ConfigurationError, /#{key} can't be set through params/)
        end
    end

    it "rejects the camelCase and plural request keys of the Gemini, Bedrock Converse, and Mistral protocols" do
      %i[systemInstruction cachedContent toolConfig tool_config outputConfig inputs].each do |key|
        expect { base.squishling(params: { key => {} }) }
          .to raise_error(Squishling::ConfigurationError, /#{key} can't be set through params/)
      end
    end

    it "allows provider-specific nested config such as Gemini's generationConfig" do
      base.squishling(params: { generationConfig: { topK: 5 } })

      expect(generation_for(base)).to eq(provider_options: { generationConfig: { topK: 5 } })
    end

    it "rejects every reserved nested key inside each allowed container, as symbols or strings" do
      Squishling::Params::NESTED_RESERVED_KEYS.each do |container, reserved|
        reserved.each do |key|
          [{ container => { key => 1, top_p: 0.5 } }, { container.to_s => { key.to_s => 1 } }].each do |params|
            expect { base.squishling(params:) }
              .to raise_error(Squishling::ConfigurationError, /#{container}\.#{key} can't be set through params/)
          end
        end
      end
    end

    it "rejects a reserved nested key even when its value is nil" do
      expect { base.squishling(params: { generationConfig: { responseMimeType: nil } }) }
        .to raise_error(Squishling::ConfigurationError, /generationConfig\.responseMimeType/)
    end

    it "rejects a non-Hash container, which would replace the one that carries the strict format" do
      ["x", [], 5].each do |value|
        expect { base.squishling(params: { generationConfig: value }) }
          .to raise_error(Squishling::ConfigurationError, /generationConfig must be a Hash/)
      end
    end

    it "freezes validated containers so they can't be mutated after the check" do
      container = { topK: 5 }
      params = described_class.normalize({ generationConfig: container }, "params")

      expect(params[:generationConfig]).to be_frozen
      expect { params[:generationConfig][:responseMimeType] = "text/plain" }.to raise_error(FrozenError)
      expect(container).not_to be_frozen
    end

    it "applies the nested check to default_params and method params too" do
      expect { Squishling.configure { |c| c.default_params = { generationConfig: { responseSchema: {} } } } }
        .to raise_error(Squishling::ConfigurationError, /generationConfig\.responseSchema/)
      expect { base.squish(:x, params: { completion_args: { tools: [] } }) { string :value } }
        .to raise_error(Squishling::ConfigurationError, /completion_args\.tools/)
    end

    it "still allows other settings in those containers, and nil to unset one" do
      base.squishling(params: { generationConfig: { topK: 5, topP: 0.9 }, completion_args: { top_p: 0.5 } })
      expect(generation_for(base)).to eq(
        provider_options: { generationConfig: { topK: 5, topP: 0.9 }, completion_args: { top_p: 0.5 } }
      )

      base.squish(:plain, params: { generationConfig: nil, completion_args: nil }) { string :value }
      expect(generation_for(base, :plain)).to eq({})
    end

    it "rejects a malformed thinking value" do
      [:low, {}, { level: :low }, { effort: nil }].each do |thinking|
        expect { base.squishling(params: { thinking: }) }
          .to raise_error(Squishling::ConfigurationError, /thinking must be true, false, or a Hash/)
      end
    end
  end

  describe "provider rejections (400 Bad Request)" do
    let(:rejection) do
      RubyLLM::BadRequestError.new("Unsupported value: 'temperature' does not support 0.1 with this model.")
    end

    it "raises a ConfigurationError that points at the params" do
      base.squishling(params: { temperature: 0.1 })
      stub_llm(rejection)

      expect { base.call }.to raise_error(Squishling::ConfigurationError) do |e|
        expect(e.message).to include("provider rejected the request", { temperature: 0.1 }.inspect, "reasoning models")
        expect(e.cause).to equal(rejection)
      end
    end

    it "omits the params hint when no params are set" do
      stub_llm(RubyLLM::BadRequestError.new("Invalid schema"))

      expect { base.call }.to raise_error(Squishling::ConfigurationError) do |e|
        expect(e.message).to include("Invalid schema")
        expect(e.message).not_to include("Check params")
      end
    end

    it "is never sent to squish_fallback" do
      base.squish_fallback { |_error, **| { value: "fallback" } }
      stub_llm(rejection)

      expect { base.call }.to raise_error(Squishling::ConfigurationError)
    end

    it "turns RubyLLM's local ArgumentError for unsupported settings into a ConfigurationError" do
      rejecting_chat = Class.new(FakeChat) do
        def with_thinking(*, **) = raise(ArgumentError, "budget exceeds the model's maximum")
      end
      allow(RubyLLM).to receive(:chat) { rejecting_chat.new(model: nil, responses: []) }
      base.squishling(params: { thinking: { budget: 999_999 } })

      expect { base.call }.to raise_error(Squishling::ConfigurationError, /invalid params.*budget exceeds/)
    end

    it "keeps context-length errors as LLMError, since they depend on the input" do
      stub_llm(RubyLLM::ContextLengthExceededError.new("too long"))

      expect { base.call }.to raise_error(Squishling::LLMError)
    end
  end
end
