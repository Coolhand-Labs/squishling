# frozen_string_literal: true

require "ruby_llm"

RSpec.describe Squishling::Adapters::RubyLLM do
  # Stand-in for RubyLLM::Chat: records configuration and replays canned responses.
  let(:reply_class) { Struct.new(:content, :model, :tokens, :finish_reason) }
  let(:fake_chat_class) do
    reply = reply_class
    Class.new do
      attr_reader :options, :instructions, :schema, :added, :asked, :generation

      def initialize(options, responses)
        @options = options
        @responses = responses
        @added = []
        @asked = []
        @generation = {}
      end

      def with_instructions(text) = tap { @instructions = text }
      def with_schema(schema) = tap { @schema = schema }
      def with_temperature(value) = tap { @generation[:temperature] = value }
      def with_max_output_tokens(value) = tap { @generation[:max_output_tokens] = value }
      def with_provider_options(value) = tap { @generation[:provider_options] = value }

      def with_thinking(enabled = true, **options) # rubocop:disable Style/OptionalBooleanParameter -- mirrors RubyLLM
        tap { @generation[:thinking] = options.empty? ? enabled : options }
      end

      def add_message(attributes) = @added << attributes

      define_method(:ask) do |message|
        @asked << message
        response = @responses.shift
        raise response if response.is_a?(Exception)

        response.is_a?(reply) ? response : reply.new(response)
      end
    end
  end

  let(:adapter) { described_class.new }
  let(:chats) { [] }

  def stub_chat(*responses)
    allow(RubyLLM).to receive(:chat) do |**options|
      fake_chat_class.new(options, responses).tap { |chat| chats << chat }
    end
  end

  it "is registered as :ruby_llm" do
    expect(Squishling.adapters).to include(:ruby_llm)
    expect(Squishling::Adapter.build(:ruby_llm, "test")).to be_a(described_class)
  end

  it "raises ConfigurationError, naming the gem, when ruby_llm can't be loaded" do
    instance = described_class.allocate
    missing = LoadError.new("cannot load such file -- ruby_llm").tap do |error|
      error.define_singleton_method(:path) { "ruby_llm" }
    end
    allow(instance).to receive(:require).with("ruby_llm").and_raise(missing)

    expect { instance.send(:initialize) }.to raise_error(Squishling::ConfigurationError, /needs the ruby_llm gem/)
  end

  it "refuses a ruby_llm older than 2.1, which lacks the APIs it uses" do
    old = instance_double(Gem::Specification, version: Gem::Version.new("2.0.3"))
    allow(Gem).to receive(:loaded_specs).and_return("ruby_llm" => old)

    expect { described_class.new }
      .to raise_error(Squishling::ConfigurationError, /needs ruby_llm 2\.1 or newer, got 2\.0\.3/)
  end

  it "supports judgments" do
    expect(adapter.judgments?).to be(true)
  end

  describe "#complete" do
    it "builds a chat on the model with the system prompt and the strict schema" do
      stub_chat({ "label" => "ok" })

      response = adapter.complete(adapter_request)

      expect(chats.first.options).to eq(model: "gpt-test")
      expect(chats.first).to have_attributes(instructions: "Classify.", schema: adapter_request.schema, asked: ["hi"],
        added: [])
      expect(response).to be_a(Squishling::Adapter::Response)
      expect(response.content).to eq("label" => "ok")
    end

    it "reports the model and the token counts RubyLLM reports" do
      tokens = RubyLLM::Tokens.new(input: 10, output: 5)
      stub_chat(reply_class.new({ "label" => "ok" }, "served-model", tokens))

      response = adapter.complete(adapter_request)

      expect(response.model).to eq("served-model")
      expect(response.tokens).to include(input_tokens: 10, output_tokens: 5)
    end

    it "reports the finish reason RubyLLM reports, nil when it reports none" do
      stub_chat(reply_class.new("", nil, nil, :max_tokens))
      expect(adapter.complete(adapter_request).finish_reason).to eq(:max_tokens)

      stub_chat("{}")
      expect(adapter.complete(adapter_request).finish_reason).to be_nil
    end

    it "reports no tokens as an empty Hash" do
      stub_chat("{}")

      expect(adapter.complete(adapter_request).tokens).to eq({})
    end

    it "replays the conversation so far, then asks the last message" do
      stub_chat("{}")
      messages = [{ role: :user, content: "first" }, { role: :assistant, content: "bad" },
                  { role: :user, content: "try again" }]

      adapter.complete(adapter_request(messages:))

      expect(chats.first.added).to eq([{ role: :user, content: "first" }, { role: :assistant, content: "bad" }])
      expect(chats.first.asked).to eq(["try again"])
    end

    it "assumes a model exists when it's missing from RubyLLM's registry and a provider is given" do
      stub_chat("{}")

      adapter.complete(adapter_request(model: "gpt-unknown", provider: :openai))

      expect(chats.first.options).to eq(model: "gpt-unknown", provider: :openai, assume_model_exists: true)
    end

    it "keeps registry lookups for known models" do
      stub_chat("{}")

      adapter.complete(adapter_request(model: "claude-haiku-4-5", provider: :anthropic))

      expect(chats.first.options).to eq(model: "claude-haiku-4-5", provider: :anthropic)
    end

    it "uses RubyLLM's default model when the request names none" do
      stub_chat("{}")

      adapter.complete(adapter_request(model: nil))

      expect(chats.first.options).to eq({})
    end

    describe "params" do
      it "maps temperature, max_output_tokens and thinking to RubyLLM's setters and passes the rest through" do
        stub_chat("{}")

        adapter.complete(adapter_request(params: { temperature: 0.1, max_output_tokens: 800, thinking: { effort: :low },
                                                   top_p: 0.9, max_tokens: 500 }))

        expect(chats.first.generation).to eq(
          temperature: 0.1, max_output_tokens: 800, thinking: { effort: :low },
          provider_options: { top_p: 0.9, max_tokens: 500 }
        )
      end

      it "sends nothing extra when no params are set" do
        stub_chat("{}")

        adapter.complete(adapter_request)

        expect(chats.first.generation).to eq({})
      end

      it "accepts thinking as true (model default), false (off), or options including display" do
        { true => true, false => false, { effort: :high, display: :omitted } => { effort: :high, display: :omitted } }
          .each do |thinking, sent|
            stub_chat("{}")
            adapter.complete(adapter_request(params: { thinking: }))
            expect(chats.last.generation).to eq(thinking: sent)
          end
      end

      it "turns RubyLLM's local ArgumentError for unsupported settings into a ConfigurationError" do
        stub_chat("{}")
        allow_any_instance_of(fake_chat_class).to receive(:with_thinking) # rubocop:disable RSpec/AnyInstance
          .and_raise(ArgumentError, "budget exceeds the model's maximum")

        expect { adapter.complete(adapter_request(params: { thinking: { budget: 999_999 } })) }
          .to raise_error(Squishling::ConfigurationError, /Klass#call: invalid params.*budget exceeds/)
      end
    end
  end

  describe "failures" do
    let(:leaked) { "Incorrect API key provided: sk-proj-abc***xyz; input was: patient Jane Doe" }

    {
      "bad credentials" => [RubyLLM::UnauthorizedError, Squishling::ConfigurationError],
      "a forbidden key" => [RubyLLM::ForbiddenError, Squishling::ConfigurationError],
      "a rejected request" => [RubyLLM::BadRequestError, Squishling::ConfigurationError],
      "a rate limit" => [RubyLLM::RateLimitError, Squishling::LLMError],
      "a server error" => [RubyLLM::ServerError, Squishling::LLMError],
      "an overload" => [RubyLLM::OverloadedError, Squishling::LLMError],
      "a context overflow" => [RubyLLM::ContextLengthExceededError, Squishling::LLMError],
      "a timeout" => [Faraday::TimeoutError, Squishling::LLMError],
      "a connection failure" => [Faraday::ConnectionFailed, Squishling::LLMError]
    }.each do |label, (type, raised)|
      it "maps #{label} to #{raised.name.split('::').last}, keeping the provider's message out of it and its cause" do
        error = type.new(leaked)
        stub_chat(error)

        expect { adapter.complete(adapter_request) }.to raise_error(raised, /\AKlass#call: .*#{type.name}/) do |e|
          expect(e.message).not_to include("sk-proj", "Jane Doe")
          expect(e.cause).to be_a(Squishling::Adapter::ProviderFailure)
          expect(e.cause.message).to eq(type.name)
          expect(e.cause.backtrace).to eq(error.backtrace)
        end
      end

      it "keeps the original #{label} exception as the cause with keep_cause: true" do
        error = type.new(leaked)
        stub_chat(error)

        expect { described_class.new(keep_cause: true).complete(adapter_request) }.to raise_error(raised) do |e|
          expect(e.cause).to equal(error)
        end
      end
    end

    it "leaves the provider's response body and the response itself off the cause" do
      response = Struct.new(:status, :body).new(500, { "error" => { "message" => leaked } })
      stub_chat(RubyLLM::ServerError.new(leaked, response:))

      expect { adapter.complete(adapter_request) }.to raise_error(Squishling::LLMError) do |e|
        expect(e.cause.message).to eq("RubyLLM::ServerError, HTTP 500")
        expect(e.cause.instance_variables).to be_empty
        expect(e.cause).not_to respond_to(:response)
        expect(e.cause.inspect).not_to include("sk-proj", "Jane Doe")
      end
    end

    it "gives a Faraday transport error a sanitized cause too" do
      stub_chat(Faraday::ConnectionFailed.new("connect to https://api.example.test failed: #{leaked}"))

      expect { adapter.complete(adapter_request) }.to raise_error(Squishling::LLMError) do |e|
        expect(e.cause).to be_a(Squishling::Adapter::ProviderFailure)
        expect(e.cause.message).to eq("Faraday::ConnectionFailed")
      end
    end

    it "refuses a keep_cause: that isn't true or false" do
      expect { described_class.new(keep_cause: "yes") }
        .to raise_error(Squishling::ConfigurationError, /keep_cause: must be true or false/)
    end

    it "takes keep_cause: from a config.adapter Hash" do
      adapter = Squishling::Adapter.build({ type: :ruby_llm, keep_cause: true }, "test")
      error = RubyLLM::RateLimitError.new(leaked)
      stub_chat(error)

      expect { adapter.complete(adapter_request) }
        .to raise_error(Squishling::LLMError) { |e| expect(e.cause).to equal(error) }
    end

    it "keeps RubyLLM's own configuration message, which names a missing setting and holds no provider text" do
      missing = "Missing configuration for OpenAI: openai_api_key"
      stub_chat(RubyLLM::ConfigurationError.new(missing))

      expect { adapter.complete(adapter_request) }.to raise_error(Squishling::ConfigurationError, /#{missing}/)
    end

    it "reports the HTTP status when the provider sent one" do
      response = Struct.new(:status).new(429)
      stub_chat(RubyLLM::RateLimitError.new("slow down", response:))

      expect { adapter.complete(adapter_request) }.to raise_error(Squishling::LLMError, /RateLimitError, HTTP 429/)
    end

    it "reports the HTTP status of a Faraday error, whose response is a Hash" do
      stub_chat(Faraday::ServerError.new("upstream said no", { status: 503 }))

      expect { adapter.complete(adapter_request) }
        .to raise_error(Squishling::LLMError, /Faraday::ServerError, HTTP 503/) do |e|
          expect(e.message).not_to include("upstream")
          expect(e.cause.message).to eq("Faraday::ServerError, HTTP 503")
        end
    end

    def rejection_response(body)
      Struct.new(:status, :body).new(400, body)
    end

    def reject_with(body, params: {})
      stub_chat(RubyLLM::BadRequestError.new(leaked, response: rejection_response(body)))
      adapter.complete(adapter_request(params:))
    end

    it "points a rejected request at the one param the provider named" do
      body = { "error" => { "message" => leaked, "type" => "invalid_request_error", "param" => "temperature" } }

      expect { reject_with(body, params: { temperature: 0.1, max_output_tokens: 10 }) }
        .to raise_error(Squishling::RequestRejectedError) do |e|
          expect(e.message).to include("provider rejected the request", "invalid_request_error", ":temperature")
          expect(e.message).not_to include("max_output_tokens", "sk-proj", "Jane Doe")
          expect(e.provider_status).to eq("invalid_request_error")
          expect(e).to be_a(Squishling::ConfigurationError)
        end
    end

    it "keeps a Gemini-style status and drops a code that only repeats the HTTP status" do
      body = [{ "error" => { "code" => 400, "message" => leaked, "status" => "INVALID_ARGUMENT" } }]

      expect { reject_with(body, params: { temperature: 0.1 }) }.to raise_error(Squishling::RequestRejectedError) do |e|
        expect(e.message).to include("BadRequestError, HTTP 400, INVALID_ARGUMENT")
        expect(e.message).to include("may be invalid")
        expect(e.message).not_to include("temperature", "sk-proj", "Jane Doe")
        expect([e.provider_status, e.provider_code]).to eq(["INVALID_ARGUMENT", nil])
        expect(e.cause).to be_a(Squishling::Adapter::ProviderFailure)
        expect(e.cause.message).to eq("RubyLLM::BadRequestError, HTTP 400")
        expect(e.cause.instance_variables).to be_empty
      end
    end

    it "keeps a provider code, and leaves out a status or code that isn't a plain token" do
      body = { "error" => { "code" => "unsupported_value", "status" => leaked, "type" => "Jane Doe, sk-proj" } }

      expect { reject_with(body) }.to raise_error(Squishling::RequestRejectedError) do |e|
        expect(e.message).to include("unsupported_value")
        expect(e.message).not_to include("sk-proj", "Jane Doe")
        expect([e.provider_status, e.provider_code]).to eq([nil, "unsupported_value"])
      end
    end

    it "reads the status and body of a Faraday error, whose response is a Hash" do
      body = { "error" => { "code" => 400, "status" => "INVALID_ARGUMENT", "message" => leaked } }
      stub_chat(RubyLLM::BadRequestError.new(leaked, response: { status: 400, body: }))

      expect { adapter.complete(adapter_request) }.to raise_error(Squishling::RequestRejectedError) do |e|
        expect(e.message).to include("BadRequestError, HTTP 400, INVALID_ARGUMENT")
        expect([e.provider_status, e.provider_code]).to eq(["INVALID_ARGUMENT", nil])
      end
    end

    it "has no status or code when the provider's body carries none" do
      expect { reject_with("<html>bad</html>") }.to raise_error(Squishling::RequestRejectedError) do |e|
        expect(e.message).to include("(RubyLLM::BadRequestError, HTTP 400). The output schema or input")
        expect([e.provider_status, e.provider_code]).to eq([nil, nil])
      end
    end

    it "has no status or code when the error has no response" do
      stub_chat(RubyLLM::BadRequestError.new("Invalid schema"))

      expect { adapter.complete(adapter_request) }.to raise_error(Squishling::RequestRejectedError) do |e|
        expect(e.message).to include("provider rejected the request", "BadRequestError",
          "The output schema or input may be invalid")
        expect(e.message).not_to include("params")
        expect(e.provider_status).to be_nil
      end
    end

    it "treats an unknown model as a configuration error" do
      allow(RubyLLM).to receive(:chat).and_raise(RubyLLM::ModelNotFoundError, "Unknown model: nope")

      expect { adapter.complete(adapter_request) }.to raise_error(Squishling::ConfigurationError, /Unknown model/)
    end

    it "keeps the provider's text out of the fallback's log line, end to end" do
      klass = Class.new do
        include Squishling

        squishling model: "a"
        purpose "Classify."
        output_schema { string :label }
        squish_fallback { |_error, **| { label: "fallback" } }
      end
      logger = instance_double(Logger, debug: nil, warn: nil)
      Squishling.configure do |c|
        c.adapter = :ruby_llm
        c.logger = logger
      end
      stub_chat(RubyLLM::ServerError.new(leaked))

      expect(klass.call(text: "x").label).to eq("fallback")
      expect(logger).to have_received(:warn).with(/LLM failed, using fallback: .*RubyLLM::ServerError/)
      expect(logger).not_to have_received(:warn).with(/sk-proj|Jane Doe/)
    end

    it "does not retry a rejected request or escalate past it, end to end" do
      klass = Class.new do
        include Squishling

        squishling escalation: ["a", "b"]
        purpose "Classify."
        output_schema { string :label }
      end
      Squishling.configure { |c| c.adapter = :ruby_llm }
      stub_chat(RubyLLM::BadRequestError.new("bad"), { "label" => "ok" })

      expect { klass.call(text: "x") }.to raise_error(Squishling::ConfigurationError, /rejected the request/)
      expect(chats.size).to eq(1)
    end
  end

  describe "#judge" do
    let(:step) { Squishling::ModelPath::Step.new(model: "jev-latest", provider: nil, params: { reasoning: "fast" }, forward_rejected: true) }
    let(:questions) { { winner: { type: :choice, instructions: "Pick.", options: { a: "A", b: "B" } } } }

    def judge
      adapter.judge({ input: 1 }, questions:, step:, label: "Klass#call")
    end

    it "sends the judgment to RubyLLM.judge with the model and the step's params as provider options" do
      received = {}
      answer = Object.new
      allow(RubyLLM).to receive(:judge) do |input, questions:, **settings|
        received.merge!(input:, questions:, settings:)
        answer
      end

      expect(judge).to equal(answer)
      expect(received[:settings]).to include(model: "jev-latest", provider_options: { reasoning: "fast" })
    end

    it "builds a judgment RubyLLM's own Judge accepts: one choice question and the judgment input" do
      received = {}
      # Stubbed below RubyLLM.judge, so RubyLLM's own question and input validation runs.
      allow(RubyLLM::Judgment).to receive(:judge) do |input, questions:, **settings|
        received.merge!(input:, questions:, settings:)
        choice = RubyLLM::Choice.new(choice: :b, probabilities: { a: 0.1, b: 0.85, neither: 0.05 }, confidence: 0.85)
        RubyLLM::Judgment.new(answers: { winner: choice }, model: "jev-latest")
      end

      answer = judge[:winner]

      expect(answer.choice).to eq(:b)
      expect(received[:questions].fetch("winner").type).to eq(:choice)
      expect(received[:settings]).to include(model: "jev-latest", provider_options: { reasoning: "fast" })
    end

    it "maps an unknown judgment model to ConfigurationError" do
      allow(RubyLLM).to receive(:judge).and_raise(RubyLLM::ModelNotFoundError, "Unknown model: jev-nonexistent")

      expect { judge }.to raise_error(Squishling::ConfigurationError, /Klass#call: Unknown model: jev-nonexistent/)
    end

    it "maps a bare RubyLLM::Error without a response (a provider with no judgments) to ConfigurationError" do
      allow(RubyLLM).to receive(:judge).and_raise(RubyLLM::Error, "Anthropic doesn't support judgments")

      expect { judge }.to raise_error(Squishling::ConfigurationError, /doesn't support judgments/)
    end

    it "maps an ArgumentError raised inside RubyLLM (a judgment it can't build) to ConfigurationError" do
      ruby_llm_lib = File.join(Gem.loaded_specs["ruby_llm"].full_gem_path, "lib")
      error = ArgumentError.new("judge does not accept a model")
      error.set_backtrace(["#{ruby_llm_lib}/ruby_llm/models.rb:193:in 'resolve'"])
      allow(RubyLLM).to receive(:judge).and_raise(error)

      expect { judge }.to raise_error(Squishling::ConfigurationError, /does not accept a model/)
    end

    it "lets an ArgumentError from anywhere else (e.g. a subscriber) propagate unwrapped" do
      allow(RubyLLM).to receive(:judge).and_raise(ArgumentError, "subscriber bug")

      expect { judge }.to raise_error(ArgumentError, "subscriber bug")
    end

    it "maps failed requests like a chat's" do
      allow(RubyLLM).to receive(:judge).and_raise(RubyLLM::ServerError, "busy")

      expect { judge }.to raise_error(Squishling::LLMError, /Klass#call: RubyLLM::ServerError/)
    end

    it "gives a failed judgment request a sanitized cause, the original with keep_cause: true" do
      response = Struct.new(:status, :body).new(500, "echoed Jane Doe")
      error = RubyLLM::ServerError.new("echoed Jane Doe", response:)
      allow(RubyLLM).to receive(:judge).and_raise(error)

      expect { judge }.to raise_error(Squishling::LLMError) do |e|
        expect(e.cause).to be_a(Squishling::Adapter::ProviderFailure)
        expect(e.cause.message).to eq("RubyLLM::ServerError, HTTP 500")
      end
      expect { described_class.new(keep_cause: true).judge({}, questions: {}, step:, label: "Klass#call") }
        .to raise_error(Squishling::LLMError) { |e| expect(e.cause).to equal(error) }
    end
  end

  describe "request context on worker threads" do
    let(:klass) do
      Class.new do
        include Squishling

        purpose "Classify."
        output_schema { string :label }
        squishling harness: { type: :squishsum }, escalation: %w[a b]
      end
    end

    before { Squishling.configure { |c| c.adapter = :ruby_llm } }

    it "carries RubyLLM's instrumentation workflow over to the request threads" do
      seen = Queue.new
      allow(RubyLLM).to receive(:chat) do |**options|
        seen << [Thread.current, RubyLLM::Support::Instrumentation.current_workflow]
        fake_chat_class.new(options, [{ "label" => "ok" }])
      end

      RubyLLM::Support::Instrumentation.with_workflow({ name: "triage" }) { klass.call(text: "x") }

      requests = [seen.pop, seen.pop]
      expect(requests.map(&:first)).not_to include(Thread.current)
      expect(requests.map(&:last)).to eq([{ name: "triage" }] * 2)
    end

    it "carries instrumentation subscribers' context over to the request threads" do
      subscriber = Object.new
      subscriber.define_singleton_method(:capture_context) { Thread.current[:squishling_spec_span] }
      subscriber.define_singleton_method(:with_context) do |span, &block|
        Thread.current[:squishling_spec_span] = span
        block.call
      ensure
        Thread.current[:squishling_spec_span] = nil
      end
      subscriber.define_singleton_method(:instrument) { |_name, _payload, &block| block.call }
      seen = Queue.new
      allow(RubyLLM).to receive(:chat) do |**options|
        seen << Thread.current[:squishling_spec_span]
        fake_chat_class.new(options, [{ "label" => "ok" }])
      end
      RubyLLM::Support::Instrumentation.subscribe(subscriber)
      Thread.current[:squishling_spec_span] = "span-1"

      klass.call(text: "x")

      expect([seen.pop, seen.pop]).to eq(%w[span-1 span-1])
    ensure
      Thread.current[:squishling_spec_span] = nil
      RubyLLM::Support::Instrumentation.unsubscribe(subscriber)
    end

    it "runs without a context when RubyLLM has none to give" do
      expect(adapter.with_context(nil) { :ran }).to eq(:ran)
    end
  end
end
