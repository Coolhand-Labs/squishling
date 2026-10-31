# frozen_string_literal: true

require "open3"

RSpec.describe Squishling::Adapter do
  let(:echo_adapter) do
    Class.new(Squishling::Adapter::Base) do
      attr_reader :requests

      def initialize(reply: '{"label":"ok"}')
        super()
        @reply = reply
        @requests = []
      end

      def complete(request)
        @requests << request
        Squishling::Adapter::Response.new(content: @reply, model: "echo-1",
          tokens: { input_tokens: 1, output_tokens: 2 })
      end
    end
  end

  let(:klass) do
    Class.new do
      include Squishling

      squishling model: "echo"
      purpose "Classify."
      output_schema { string :label }
    end
  end

  describe "Squishling::Adapter::Base" do
    let(:base) { Squishling::Adapter::Base.new }

    it "makes a finish reason a Symbol, nil when blank, and truncated? when the output cap cut it off" do
      response = ->(reason) { Squishling::Adapter::Response.new(content: "{}", finish_reason: reason) }

      expect(response.call("length")).to have_attributes(finish_reason: :length, truncated?: false)
      expect(response.call(:max_tokens)).to have_attributes(finish_reason: :max_tokens, truncated?: true)
      expect(response.call(" ")).to have_attributes(finish_reason: nil, truncated?: false)
      expect(response.call(nil).finish_reason).to be_nil
    end

    it "builds a Response with only content, and treats nil tokens as none" do
      response = Squishling::Adapter::Response.new(content: "{}", tokens: nil)

      expect(response).to have_attributes(model: nil, tokens: {}, usage: nil)
      expect(Squishling::Adapter::Response.new(content: "{}", tokens: { input_tokens: 1 }).usage)
        .to eq(input_tokens: 1)
    end

    it "refuses tokens that aren't a Hash" do
      expect { Squishling::Adapter::Response.new(content: "{}", tokens: Struct.new(:input).new(1)) }
        .to raise_error(Squishling::ConfigurationError, /tokens must be a Hash/)
    end

    it "sends a reply with undecodable bytes back as valid UTF-8 text" do
      text = Squishling::Adapter::Response.new(content: "ab\xFFc".dup.force_encoding("UTF-8")).text
      binary = Squishling::Adapter::Response.new(content: "caf\xC3\xA9".b).text

      expect([text, binary]).to eq(["ab?c", "café"])
      expect(JSON.generate([text, binary])).to be_a(String)
    end

    it "requires #complete" do
      expect { base.complete(nil) }.to raise_error(NotImplementedError, /must implement #complete/)
    end

    it "doesn't support judgments by default, and says so" do
      expect(base.judgments?).to be(false)
      expect { base.judge({}, questions: {}, step: nil, label: "K#m") }
        .to raise_error(Squishling::ConfigurationError, /doesn't support judgments/)
    end

    it "gives a custom adapter rejected_request_error, which repeats only the body's status and code" do
      request = Squishling::Adapter::Request.new(label: "K#m", model: nil, provider: nil, instructions: nil,
        messages: [], schema: nil, params: { top_p: 1 })
      body = JSON.generate(error: { message: "echoed secret", status: "INVALID_ARGUMENT", param: "top_p" })

      error = base.send(:rejected_request_error, request, via: "MyClient, HTTP 400", body:)

      expect(error).to be_a(Squishling::ConfigurationError)
      expect(error.message).to eq("K#m: the provider rejected the request (MyClient, HTTP 400, INVALID_ARGUMENT). " \
                                  "The provider named the :top_p param; check its value.")
      expect(error.provider_status).to eq("INVALID_ARGUMENT")
    end

    it "points at a param only when the provider's field is that param or inside it" do
      request = lambda do |params|
        Squishling::Adapter::Request.new(label: "K#m", model: nil, provider: nil, instructions: nil, messages: [],
          schema: nil, params:)
      end
      hint = lambda do |params, field|
        body = JSON.generate(error: { param: field })
        base.send(:rejected_request_error, request.call(params), via: "Acme", body:).message
      end

      expect(hint.call({ thinking: { budget: 1 } }, "thinking.budget_tokens")).to include(":thinking param")
      expect(hint.call({ "stop" => ["x"] }, "stop[0]")).to include('"stop" param')
      expect(hint.call({ thinking_x: 1 }, "thinking")).to include("may be invalid")
      expect(hint.call({ temperature: 1 }, nil)).to include("may be invalid")
    end

    it "drops a code that repeats the http_status it was given, whatever via says" do
      request = Squishling::Adapter::Request.new(label: "K#m", model: nil, provider: nil, instructions: nil,
        messages: [], schema: nil, params: {})
      body = JSON.generate(error: { code: 400, status: "INVALID_ARGUMENT" })

      error = base.send(:rejected_request_error, request, via: "Acme", body:, http_status: 400)

      expect(error.provider_code).to be_nil
      expect(error.message).to include("(Acme, INVALID_ARGUMENT)")
    end

    describe "#http_failure" do
      let(:request) do
        Squishling::Adapter::Request.new(label: "K#m", model: nil, provider: nil, instructions: nil, messages: [],
          schema: nil, params: {})
      end
      let(:overflow) { JSON.generate(error: { code: "context_length_exceeded", message: "echoed secret" }) }

      def failure(adapter, status, body = "{}")
        adapter.send(:http_failure, request, status:, body:, via: "Acme, HTTP #{status}")
      end

      it "gives a custom adapter the same status mapping as the built-ins, repeating only via" do
        classes = [400, 401, 402, 403, 404, 301, 408, 413, 429, 500, 422].to_h do |status|
          [status, failure(base, status).class]
        end

        expect(classes).to eq(
          400 => Squishling::RequestRejectedError, 401 => Squishling::ConfigurationError,
          402 => Squishling::ConfigurationError, 403 => Squishling::ConfigurationError,
          404 => Squishling::ConfigurationError, 301 => Squishling::ConfigurationError,
          408 => Squishling::LLMError, 413 => Squishling::LLMError, 429 => Squishling::LLMError,
          500 => Squishling::LLMError, 422 => Squishling::RequestRejectedError
        )
        expect(failure(base, 500).message).to eq("K#m: Acme, HTTP 500")
      end

      it "treats a failure with no HTTP status as an LLMError" do
        expect(base.send(:http_failure, request, status: nil, body: nil, via: "Acme")).to be_a(Squishling::LLMError)
      end

      it "recognizes a structured overflow on a 400 by default, and leaves any other wording a rejection" do
        wording = JSON.generate(error: { message: "context length exceeded" })

        expect(failure(base, 400, overflow)).to be_a(Squishling::LLMError)
        expect(failure(base, 422, overflow)).to be_a(Squishling::RequestRejectedError)
        expect(failure(base, 400, wording)).to be_a(Squishling::RequestRejectedError)
      end

      it "lets an adapter decide what an overflow looks like for its provider" do
        acme = Class.new(Squishling::Adapter::Base) do
          def context_length?(status:, body:)
            super || (status == 400 && body.to_s.include?("TOO_LONG"))
          end
        end.new

        expect(failure(acme, 400, "TOO_LONG")).to be_a(Squishling::LLMError)
        expect(failure(acme, 400, overflow)).to be_a(Squishling::LLMError)
        expect(failure(acme, 400, "bad")).to be_a(Squishling::RequestRejectedError)
      end
    end

    it "carries no context by default" do
      expect(base.capture_context).to be_nil
      expect(base.with_context(nil) { :ran }).to eq(:ran)
    end
  end

  describe "configuring" do
    it "accepts an instance" do
      adapter = echo_adapter.new
      Squishling.configure { |c| c.adapter = adapter }

      expect(Squishling.config.adapter).to equal(adapter)
      expect(Squishling.config.resolved_adapter).to equal(adapter)
    end

    it "accepts any object that responds to complete" do
      duck = Object.new.tap { |o| o.define_singleton_method(:complete) { |_r| nil } }
      Squishling.configure { |c| c.adapter = duck }

      expect(Squishling.config.adapter).to equal(duck)
    end

    it "accepts a built-in name as a Symbol or String, or a Hash with type: and options" do
      Squishling.configure { |c| c.adapter = :ruby_llm }
      expect(Squishling.config.adapter).to be_a(Squishling::Adapters::RubyLLM)

      Squishling.configure { |c| c.adapter = "openai_compatible" }
      expect(Squishling.config.adapter).to be_a(Squishling::Adapters::OpenAICompatible)

      Squishling.configure { |c| c.adapter = { "type" => "openai_compatible", "default_model" => "llama3" } }
      expect(Squishling.config.adapter).to be_a(Squishling::Adapters::OpenAICompatible)
    end

    it "rejects what isn't an adapter, before any request" do
      [42, Object.new, [], :nope].each do |bad|
        expect do
          Squishling.configure do |c|
            c.adapter = bad
          end
        end.to raise_error(Squishling::ConfigurationError, /adapter/)
      end
      expect { Squishling.configure { |c| c.adapter = {} } }
        .to raise_error(Squishling::ConfigurationError, /needs a type:/)
    end

    it "lists the available adapters in the message for an unknown one" do
      expect { Squishling.configure { |c| c.adapter = :bogus } }
        .to raise_error(Squishling::ConfigurationError,
          /unknown adapter :bogus \(available: :ruby_llm, :openai_compatible\)/)
    end

    it "surfaces a bad option while configuring" do
      expect { Squishling.configure { |c| c.adapter = { type: :openai_compatible, max_retries: -1 } } }
        .to raise_error(Squishling::ConfigurationError, /max_retries/)
    end

    it "turns an unknown or missing adapter option into a ConfigurationError naming the options it takes" do
      expect { Squishling.configure { |c| c.adapter = { type: :openai_compatible, bogus: 1 } } }
        .to raise_error(Squishling::ConfigurationError, /doesn't take bogus \(options: base_url, api_key/)
      expect { Squishling.configure { |c| c.adapter = { type: :ruby_llm, x: 1 } } }
        .to raise_error(Squishling::ConfigurationError, /doesn't take x/)
      Squishling.register_adapter(:strict_one, Class.new(echo_adapter) { def initialize(needed:) = super() && needed })
      expect { Squishling.configure { |c| c.adapter = :strict_one } }
        .to raise_error(Squishling::ConfigurationError, /needs needed/)
    ensure
      Squishling.reset_adapters!
    end

    it "lets an adapter that takes **options accept any" do
      Squishling.register_adapter(:loose, Class.new(echo_adapter) { def initialize(**) = super() })
      Squishling.configure { |c| c.adapter = { type: :loose, anything: 1 } }

      expect(Squishling.config.adapter).to respond_to(:complete)
    ensure
      Squishling.reset_adapters!
    end

    it "clears the adapter again with nil" do
      Squishling.configure { |c| c.adapter = echo_adapter.new }
      Squishling.configure { |c| c.adapter = nil }

      expect(Squishling.config.adapter).to be_nil
    end
  end

  describe "auto-detection" do
    it "uses RubyLLM when nothing is configured and the gem is available" do
      expect(Squishling.config.adapter).to be_nil
      expect(Squishling.config.resolved_adapter).to be_a(Squishling::Adapters::RubyLLM)
    end

    it "builds the detected adapter once" do
      expect(Squishling.config.resolved_adapter).to equal(Squishling.config.resolved_adapter)
    end

    it "raises a ConfigurationError saying what to do when ruby_llm isn't there" do
      allow(Squishling::Adapters::RubyLLM).to receive(:new)
        .and_raise(Squishling::Adapters::RubyLLM::MissingGemError, "adapter :ruby_llm needs the ruby_llm gem")

      expect { Squishling.config.resolved_adapter }
        .to raise_error(Squishling::ConfigurationError, /No adapter is configured.*gem "ruby_llm".*config\.adapter/)
    end

    it "reports a ruby_llm that is installed but too old as such, not as a missing gem" do
      old = instance_double(Gem::Specification, version: Gem::Version.new("2.0.3"))
      allow(Gem).to receive(:loaded_specs).and_return("ruby_llm" => old)

      expect { Squishling.config.resolved_adapter }
        .to raise_error(Squishling::ConfigurationError, /needs ruby_llm 2\.1 or newer, got 2\.0\.3/)
    end

    it "fails the squished call, before any request, when there is no adapter to use" do
      allow(Squishling::Adapters::RubyLLM).to receive(:new)
        .and_raise(Squishling::Adapters::RubyLLM::MissingGemError, "missing")

      expect { klass.call(text: "x") }.to raise_error(Squishling::ConfigurationError, /No adapter is configured/)
    end

    it "prefers a configured adapter over detection" do
      adapter = echo_adapter.new
      Squishling.configure { |c| c.adapter = adapter }
      expect(Squishling::Adapters::RubyLLM).not_to receive(:new)

      expect(Squishling.config.resolved_adapter).to equal(adapter)
    end
  end

  describe "without ruby_llm" do
    it "loads Squishling without requiring ruby_llm" do
      script = 'require "squishling"; abort("ruby_llm was loaded") if defined?(::RubyLLM); ' \
               "Squishling::Adapters::OpenAICompatible.new; print :ok"
      output, status = Open3.capture2e(RbConfig.ruby, "-rbundler/setup", "-I", File.expand_path("../../lib", __dir__),
        "-e", script)

      expect([status.success?, output.lines.last]).to eq([true, "ok"])
    end

    it "keeps every use of RubyLLM out of the code outside the RubyLLM adapter" do
      files = Dir[File.expand_path("../../lib/**/*.rb", __dir__)].reject do |file|
        file.end_with?("adapters/ruby_llm.rb")
      end
      uses = files.select do |file|
        code = File.readlines(file).reject { |line| line.strip.start_with?("#") }.join.gsub("Adapters::RubyLLM", "")
        code.match?(/\bRubyLLM\b|require ["']ruby_llm/)
      end

      expect(uses).to be_empty
    end

    it "reports an unrelated LoadError from inside ruby_llm as it is" do
      instance = Squishling::Adapters::RubyLLM.allocate
      error = LoadError.new("cannot load such file -- faraday/net_http")
      error.define_singleton_method(:path) { "faraday/net_http" }
      allow(instance).to receive(:require).with("ruby_llm").and_raise(error)

      expect { instance.send(:initialize) }.to raise_error(LoadError, /faraday/)
    end
  end

  describe "registering your own" do
    after { Squishling.reset_adapters! }

    it "makes the name usable as config.adapter, with options" do
      Squishling.register_adapter(:echo, echo_adapter)
      Squishling.configure { |c| c.adapter = { type: :echo, reply: '{"label":"hi"}' } }

      expect(Squishling.adapters).to include(:echo)
      expect(klass.call(text: "x").label).to eq("hi")
    end

    it "builds a registered adapter from its name alone" do
      Squishling.register_adapter("echo", echo_adapter)
      Squishling.configure { |c| c.adapter = :echo }

      expect(Squishling.config.adapter).to be_a(echo_adapter)
    end

    it "rejects a taken or built-in name, a bad name, and something that isn't an adapter class" do
      Squishling.register_adapter(:echo, echo_adapter)

      expect { Squishling.register_adapter(:echo, echo_adapter) }
        .to raise_error(Squishling::ConfigurationError, /already registered/)
      expect { Squishling.register_adapter(:ruby_llm, echo_adapter) }
        .to raise_error(Squishling::ConfigurationError, /already registered/)
      expect { Squishling.register_adapter("Bad Name", echo_adapter) }
        .to raise_error(Squishling::ConfigurationError, /lowercase letters/)
      expect { Squishling.register_adapter(42, echo_adapter) }
        .to raise_error(Squishling::ConfigurationError, /must be a Symbol or String/)
      expect { Squishling.register_adapter(:odd, Class.new) }
        .to raise_error(Squishling::ConfigurationError, /implements #complete/)
      expect { Squishling.register_adapter(:odd, Class.new(Squishling::Adapter::Base)) }
        .to raise_error(Squishling::ConfigurationError, /implements #complete/)
      expect { Squishling.register_adapter(:odd, echo_adapter.new) }
        .to raise_error(Squishling::ConfigurationError, /implements #complete/)
    end

    it "forgets custom adapters on reset, keeping the built-ins" do
      Squishling.register_adapter(:echo, echo_adapter)
      Squishling.reset_adapters!

      expect(Squishling.adapters).to eq(%i[ruby_llm openai_compatible])
    end
  end

  describe "a custom adapter through a squished call" do
    let(:adapter) { echo_adapter.new }

    before { Squishling.configure { |c| c.adapter = adapter } }

    it "gets the label, model, system prompt, strict schema, params and messages" do
      klass.squishling(provider: :acme, params: { temperature: 0.3 })

      result = klass.call(text: "x")

      expect(result.label).to eq("ok")
      expect(result).to be_squished
      expect(adapter.requests.first).to have_attributes(
        label: a_string_ending_with("#call"), model: "echo", provider: :acme, params: { temperature: 0.3 },
        instructions: a_string_starting_with("Classify."),
        messages: [{ role: :user, content: JSON.generate(arguments: { text: "x" }) }]
      )
      expect(adapter.requests.first.schema).to include("strict" => true, "schema" => hash_including("type" => "object"))
    end

    it "validates what comes back, retrying in the same conversation with the adapter's own reply replayed" do
      klass.squishling(escalation: [{ model: "echo", attempts: 2 }])
      replies = ['{"label":1}', '{"label":"fixed"}']
      allow(adapter).to receive(:complete).and_wrap_original do |original, request|
        original.call(request).with(content: replies.shift)
      end

      expect(klass.call(text: "x").label).to eq("fixed")
      second = adapter.requests.last
      expect(second.messages.map { |m| m[:role] }).to eq(%i[user assistant user])
      expect(second.messages[1][:content]).to eq('{"label":1}')
      expect(second.messages.last[:content]).to include("not a string")
    end

    it "sends a Hash the adapter already parsed back to it as JSON in a retry" do
      klass.squishling(escalation: [{ model: "echo", attempts: 2 }])
      replies = [{ "label" => 1 }, { "label" => "ok" }]
      allow(adapter).to receive(:complete).and_wrap_original do |original, request|
        original.call(request).with(content: replies.shift)
      end

      klass.call(text: "x")

      expect(adapter.requests.last.messages[1][:content]).to eq('{"label":1}')
    end

    it "gives the adapter no inputs beyond the request" do
      klass.call(text: "secret")

      expect(adapter.requests.first.to_h.keys).to eq(%i[label model provider instructions messages schema params])
    end

    it "tells the observer the model and tokens the adapter reported, nothing else" do
      seen = []
      observer = Object.new
      observer.define_singleton_method(:around) { |_call, &block| seen << block.call }
      Squishling.configure { |c| c.observer = observer }

      klass.call(text: "x")

      expect(seen).to eq([Squishling::Observer::Usage.new(input_tokens: 1, output_tokens: 2, model: "echo-1")])
    end

    it "reports the adapter's tokens as squawk usage" do
      reports = []
      klass.squishling(squawk: ->(metadata:, **) { reports << metadata })

      klass.call(text: "x")

      expect(reports.first).to include(model: "echo-1", usage: { input_tokens: 1, output_tokens: 2 })
    end

    it "doesn't count a duck-typed adapter that claims judgments without a judge method" do
      duck = Object.new
      duck.define_singleton_method(:judgments?) { true }
      duck.define_singleton_method(:complete) { |_request| nil }
      Squishling.configure { |c| c.adapter = duck }
      klass.squishling(escalation: %w[a b],
        harness: { type: :judged_squishsum, judge: { model: "jev", type: :judgment } })

      expect { klass.call(text: "x") }.to raise_error(Squishling::ConfigurationError, /supports judgments/)
    end

    it "refuses a type: :judgment judge, before any request, when the adapter has no judgments" do
      klass.squishling(escalation: %w[a b],
        harness: { type: :judged_squishsum, judge: { model: "jev", type: :judgment } })

      expect { klass.call(text: "x") }
        .to raise_error(Squishling::ConfigurationError, /needs an adapter that supports judgments/)
      expect(adapter.requests).to be_empty
    end

    it "runs a type: :chat judge on any adapter" do
      klass.squishling(escalation: %w[a b], harness: { type: :judged_squishsum, judge: "c" })
      replies = ['{"label":"x"}', '{"label":"y"}', '{"verdict":"a","reason":"first"}']
      allow(adapter).to receive(:complete).and_wrap_original do |original, request|
        original.call(request).with(content: replies.shift)
      end

      expect(klass.call(text: "x").label).to eq("x")
      expect(adapter.requests.size).to eq(3)
    end
  end

  describe "an adapter with judgments" do
    it "answers a type: :judgment judge through #judge, with the label and step" do
      adapter = echo_adapter.new
      calls = []
      adapter.define_singleton_method(:judgments?) { true }
      adapter.define_singleton_method(:judge) do |input, step:, label:, **|
        calls << { input:, step:, label: }
        { winner: Struct.new(:choice, :probabilities).new(:a, { a: 0.95, b: 0.05 }) }
      end
      Squishling.configure { |c| c.adapter = adapter }
      klass.squishling(escalation: %w[a b],
        harness: { type: :judged_squishsum, judge: { model: "jev", type: :judgment } })
      replies = ['{"label":"x"}', '{"label":"y"}']
      allow(adapter).to receive(:complete).and_wrap_original do |original, request|
        original.call(request).with(content: replies.shift)
      end

      expect(klass.call(text: "x").label).to eq("x")
      expect(calls.first).to include(label: a_string_ending_with("#call"), step: have_attributes(model: "jev"))
    end
  end
end
