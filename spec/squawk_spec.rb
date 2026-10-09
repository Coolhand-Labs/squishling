# frozen_string_literal: true

RSpec.describe "Squishling squawk" do
  let(:calls) { [] }
  let(:recorder) { ->(**payload) { calls << payload } }
  let(:klass) do
    Class.new do
      include Squishling

      squishling escalation: [{ model: "test-model", attempts: 2 }]
      instructions "Classify."
      output_schema { string :label }

      def initialize
        @secret = "SECRET_IVAR"
      end
    end
  end

  describe "by default" do
    it "does nothing and leaves the call unchanged" do
      stub_llm({ "label" => "ok" })

      expect(klass.call(text: "x").label).to eq("ok")
    end
  end

  describe "what the hook receives" do
    before { Squishling.configure { |c| c.squawk = recorder } }

    it "gets the raw output, no error, and metadata for an accepted attempt" do
      stub_llm({ "label" => "ok" })
      klass.call(text: "x")

      expect(calls.size).to eq(1)
      call = calls.first
      expect(call[:output]).to eq("label" => "ok")
      expect(call[:error]).to be_nil
      expect(call[:metadata]).to include(
        label: "#{klass}#call", attempt: 1, attempts: 2, final: false, model: "test-model", params: {}
      )
      expect(JSON.parse(call[:metadata][:input])).to eq("arguments" => { "text" => "x" })
    end

    it "fires for each attempt, with the rejection as the error" do
      stub_llm({ "label" => 1 }, { "label" => "ok" })
      klass.call(text: "x")

      rejected, accepted = calls
      expect(rejected[:error]).to be_a(Squishling::InvalidOutputError)
      expect(rejected[:error].raw).to eq("label" => 1)
      expect(rejected[:output]).to eq("label" => 1)
      expect(rejected[:metadata]).to include(attempt: 1, final: false)
      expect(accepted[:error]).to be_nil
      expect(accepted[:metadata]).to include(attempt: 2, final: true)
    end

    it "gets the final InvalidOutputError that is raised" do
      stub_llm('{"label": SECRET_TOKEN}', "not json")

      expect { klass.call(text: "x") }.to raise_error(Squishling::InvalidOutputError) do |raised|
        expect(calls.last[:error]).to be(raised)
        expect(calls.last[:output]).to eq("not json")
        expect(calls.first[:output]).to include("SECRET_TOKEN")
        expect(calls.first[:error].models).to eq(["test-model"])
      end
    end

    it "fires for a squish_validate rejection" do
      klass.squish_validate { |_result, **| "nope" }
      stub_llm({ "label" => "a" }, { "label" => "b" })

      expect { klass.call(text: "x") }.to raise_error(Squishling::InvalidOutputError)
      expect(calls.map { |call| call[:error].errors }).to eq([["nope"], ["nope"]])
    end

    it "fires with no output when the provider call fails" do
      error = RubyLLM::ServerError.new("boom")
      stub_llm(error, error)

      expect { klass.call(text: "x") }.to raise_error(Squishling::LLMError)
      expect(calls.map { |call| call[:output] }).to eq([nil, nil])
      expect(calls.map { |call| call[:error] }).to all(be_a(Squishling::LLMError))
      expect(calls.last[:metadata]).to include(final: true)
    end

    it "doesn't fire for a configuration error" do
      stub_llm(RubyLLM::UnauthorizedError.new("bad key"))

      expect { klass.call(text: "x") }.to raise_error(Squishling::ConfigurationError)
      expect(calls).to be_empty
    end

    it "doesn't send instance variables with the input" do
      stub_llm({ "label" => "ok" })
      klass.call(text: "x")

      expect(calls.first[:metadata][:input]).not_to include("SECRET_IVAR")
    end

    it "includes the response's model and token usage when RubyLLM reports them" do
      tokens = instance_double(RubyLLM::Tokens, to_h: { input_tokens: 3, output_tokens: 4 })
      stub_llm(FakeChat::Response.new({ "label" => "ok" }, "served-model", tokens))
      klass.call(text: "x")

      expect(calls.first[:metadata]).to include(model: "served-model", usage: { input_tokens: 3, output_tokens: 4 })
    end

    it "lets an exception raised by the hook propagate unchanged" do
      Squishling.configure { |c| c.squawk = ->(**) { raise ArgumentError, "tracer down" } }
      stub_llm({ "label" => "ok" })

      expect { klass.call(text: "x") }.to raise_error(ArgumentError, "tracer down")
    end
  end

  describe "keywords" do
    it "passes only the keywords the hook declares" do
      seen = []
      Squishling.configure { |c| c.squawk = ->(error:) { seen << error } }
      stub_llm({ "label" => 1 }, { "label" => "ok" })
      klass.call(text: "x")

      expect(seen.map(&:class)).to eq([Squishling::InvalidOutputError, NilClass])
    end

    it "passes everything to a hook that takes **" do
      Squishling.configure { |c| c.squawk = ->(output:, **rest) { calls << [output, rest.keys.sort] } }
      stub_llm({ "label" => "ok" })
      klass.call(text: "x")

      expect(calls).to eq([[{ "label" => "ok" }, %i[error metadata]]])
    end

    it "accepts a zero-argument lambda, a proc, and a Method" do
      seen = calls
      recorder_class = Class.new { define_singleton_method(:record) { |output:| seen << output } }
      [-> { seen << :lambda }, proc { seen << :proc }, recorder_class.method(:record)].each do |hook|
        Squishling.configure { |c| c.squawk = hook }
        stub_llm({ "label" => "ok" })
        klass.call(text: "x")
      end

      expect(calls).to eq([:lambda, :proc, { "label" => "ok" }])
    end

    it "accepts any object that responds to call" do
      seen = calls
      hook = Object.new
      hook.define_singleton_method(:call) { |output:, **| seen << output }
      Squishling.configure { |c| c.squawk = hook }
      stub_llm({ "label" => "ok" })
      klass.call(text: "x")

      expect(calls).to eq([{ "label" => "ok" }])
    end
  end

  describe "precedence" do
    let(:config_calls) { [] }
    let(:class_calls) { [] }
    let(:method_calls) { [] }

    before { Squishling.configure { |c| c.squawk = ->(**) { config_calls << :config } } }

    it "uses the configured hook when the class and method declare none" do
      stub_llm({ "label" => "ok" })
      klass.call(text: "x")

      expect(config_calls).to eq([:config])
    end

    it "prefers the class's hook, and a subclass inherits it" do
      klass.squishling(squawk: ->(**) { class_calls << :class })
      stub_llm({ "label" => "ok" }, { "label" => "ok" })
      klass.call(text: "x")
      Class.new(klass).call(text: "x")

      expect(class_calls).to eq(%i[class class])
      expect(config_calls).to be_empty
    end

    it "prefers the method's hook over the class's" do
      klass.squishling(squawk: ->(**) { class_calls << :class })
      klass.squish(:other, squawk: ->(**) { method_calls << :method }) { string :label }
      klass.define_method(:other) { |text:| raise NotImplementedError, text }
      stub_llm({ "label" => "ok" })
      klass.new.other(text: "x")

      expect(method_calls).to eq([:method])
      expect(class_calls).to be_empty
    end

    it "silences inherited hooks with false" do
      klass.squishling(squawk: false)
      stub_llm({ "label" => "ok" })
      klass.call(text: "x")

      expect(config_calls).to be_empty
    end

    it "lets a subclass silence its parent's hook" do
      klass.squishling(squawk: ->(**) { class_calls << :class })
      subclass = Class.new(klass) { squishling squawk: false }
      stub_llm({ "label" => "ok" })
      subclass.call(text: "x")

      expect(class_calls).to be_empty
      expect(config_calls).to be_empty
    end

    it "carries the hook through squish!" do
      klass.squishling(squawk: ->(**) { class_calls << :class })
      klass.define_method(:call) { |text:| squish! if text }
      stub_llm({ "label" => "ok" })
      klass.call(text: "x")

      expect(class_calls).to eq([:class])
    end
  end

  describe "paths that don't call the LLM" do
    before { Squishling.configure { |c| c.squawk = recorder } }

    it "doesn't fire for a deterministic return" do
      klass.squish_when { |**| false }
      klass.define_method(:call) { |text:| result(label: text) }

      expect(klass.call(text: "x").label).to eq("x")
      expect(calls).to be_empty
    end

    it "fires for the failed attempts before a fallback, but not for the fallback's return" do
      klass.squish_fallback { |_error, **| { label: "fallback" } }
      stub_llm(nil, nil)

      expect(klass.call(text: "x").label).to eq("fallback")
      expect(calls.size).to eq(2)
      expect(calls.map { |call| call[:error] }).to all(be_a(Squishling::InvalidOutputError))
    end

    it "doesn't fire when the user's own squish_validate raises" do
      klass.squish_validate { |_result, **| raise ArgumentError, "mine" }
      stub_llm({ "label" => "ok" })

      expect { klass.call(text: "x") }.to raise_error(ArgumentError, "mine")
      expect(calls).to be_empty
    end
  end

  describe "validation" do
    it "rejects a hook that can't be called" do
      expect { Squishling.configure { |c| c.squawk = "log it" } }
        .to raise_error(Squishling::ConfigurationError, /squawk must respond to call/)
      expect { klass.squishling(squawk: :log) }.to raise_error(Squishling::ConfigurationError, /squawk must respond/)
      expect { klass.squish(:call, squawk: 1) }.to raise_error(Squishling::ConfigurationError, /squawk must respond/)
    end

    it "rejects a hook that takes positional arguments" do
      expect { Squishling.configure { |c| c.squawk = ->(output, metadata, error) {} } }
        .to raise_error(Squishling::ConfigurationError, /keywords .* not positional/)
      expect { klass.squishling(squawk: proc { |output| output }) }
        .to raise_error(Squishling::ConfigurationError, /not positional/)
    end

    it "rejects a hook that requires a keyword it will never be given" do
      expect { Squishling.configure { |c| c.squawk = ->(output:, trace_id:) {} } }
        .to raise_error(Squishling::ConfigurationError, /unknown keyword\(s\) trace_id/)
      expect { klass.squishling(squawk: ->(*args) {}) }.to raise_error(Squishling::ConfigurationError, /not positional/)
    end

    it "accepts a splat that also captures keywords" do
      expect { Squishling.configure { |c| c.squawk = ->(*args, **opts) {} } }.not_to raise_error
    end

    it "accepts nil and false" do
      expect { Squishling.configure { |c| c.squawk = nil } }.not_to raise_error
      expect { Squishling.configure { |c| c.squawk = false } }.not_to raise_error
    end
  end
end
