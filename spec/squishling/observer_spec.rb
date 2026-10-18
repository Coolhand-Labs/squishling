# frozen_string_literal: true

RSpec.describe Squishling::Observer do
  let(:klass) do
    Class.new do
      include Squishling

      squishling escalation: ["claude-haiku-4-5", "claude-sonnet-5-5"]
      purpose "Triage the ticket."
      output_schema do
        string :priority
        string :team
      end

      def self.to_s = "TicketTriage"
    end
  end

  let(:high) { { "priority" => "high", "team" => "api" } }
  let(:low) { { "priority" => "low", "team" => "api" } }
  let(:bad) { { "priority" => 1 } }
  let(:events) { [] }

  # An observer that records each request's Call, and what happened around it.
  let(:recorder) do
    log = events
    Object.new.tap do |observer|
      observer.define_singleton_method(:around) do |call, &block|
        log << [:before, call, Thread.current]
        block.call.tap { log << [:after, call, Thread.current] }
      end
    end
  end

  def calls
    events.select { |kind, *| kind == :before }.map { |_, call, _| call }
  end

  describe "by default" do
    it "leaves a full call untouched, on every harness, when the coolhand gem isn't installed" do
      hide_const("Coolhand")
      stub_llm(high)
      expect(klass.call(text: "x").priority).to eq("high")

      klass.squishling(harness: :squishsum)
      stub_llm_chats([high], [high])
      expect(klass.call(text: "x").priority).to eq("high")

      klass.squishling(harness: :judged_squishsum)
      stub_llm_chats([high], [low], [{ "verdict" => "a", "reason" => "outage" }])
      expect(klass.call(text: "x").priority).to eq("high")
    end

    it "wraps nothing when Coolhand isn't loaded" do
      expect(Squishling::Observer.resolve(Squishling.config.observer)).to be_nil
      expect(Squishling::Observer.around(nil) { :request }).to eq(:request)
    end
  end

  describe "configuring" do
    it "accepts an object that responds to around, :coolhand, false, and nil" do
      stub_const("Coolhand", Module.new { def self.with_context(**) = yield })

      [recorder, :coolhand, false, nil].each do |observer|
        Squishling.configure { |c| c.observer = observer }
        expect(Squishling.config.observer).to eq(observer)
      end
    end

    it "rejects anything else at setup" do
      expect { Squishling.configure { |c| c.observer = :datadog } }
        .to raise_error(Squishling::ConfigurationError, /observer must be one of :coolhand/)
      expect { Squishling.configure { |c| c.observer = Object.new } }
        .to raise_error(Squishling::ConfigurationError, /observer must respond to around/)
      expect { Squishling.configure { |c| c.observer = ->(call) {} } }
        .to raise_error(Squishling::ConfigurationError, /observer must respond to around/)
    end
  end

  describe "a custom observer" do
    before { Squishling.configure { |c| c.observer = recorder } }

    it "wraps the request and is told where it sits" do
      stub_llm(bad, high)

      expect(klass.call(text: "x").priority).to eq("high")

      expect(events.map(&:first)).to eq(%i[before after before after])
      expect(calls).to eq([
        Squishling::Observer::Call.new(label: "TicketTriage#call", purpose: "Triage the ticket.",
          harness: :escalation, handed_off: false, role: nil, sample: nil, attempt: 1, attempts: 2,
          model: "claude-haiku-4-5", provider: nil, request: :chat),
        Squishling::Observer::Call.new(label: "TicketTriage#call", purpose: "Triage the ticket.",
          harness: :escalation, handed_off: false, role: nil, sample: nil, attempt: 2, attempts: 2,
          model: "claude-sonnet-5-5", provider: nil, request: :chat)
      ])
    end

    it "reports a declared provider, and counts repeated attempts on one model" do
      klass.squishling(escalation: [{ model: "test-model", provider: :openai, attempts: 2 }])
      stub_llm(bad, high)

      klass.call(text: "x")

      expect(calls.map { |call| [call.provider, call.model, call.attempt, call.attempts] })
        .to eq([[:openai, "test-model", 1, 2], [:openai, "test-model", 2, 2]])
    end

    it "runs the request inside the observer" do
      order = []
      observer = Object.new
      observer.define_singleton_method(:around) do |_call, &block|
        order << :enter
        block.call.tap { order << :exit }
      end
      Squishling.configure { |c| c.observer = observer }
      stub_llm(high)
      allow(RubyLLM).to receive(:chat) do |**options|
        FakeChat.new(**options, responses: [high], on_ask: ->(_) { order << :request })
      end

      klass.call(text: "x")

      expect(order).to eq(%i[enter request exit])
    end

    it "lets its own exceptions propagate unchanged" do
      boom = Class.new(StandardError)
      observer = Object.new
      observer.define_singleton_method(:around) { |_call, &_block| raise boom, "observer broke" }
      Squishling.configure { |c| c.observer = observer }
      stub_llm(high)

      expect { klass.call(text: "x") }.to raise_error(boom, "observer broke")
    end

    it "doesn't map its own RubyLLM or Faraday errors onto LLMError" do
      [Faraday::ConnectionFailed.new("exporter down"), RubyLLM::ServerError.new("exporter 500")].each do |error|
        observer = Object.new
        observer.define_singleton_method(:around) { |_call, &_block| raise error }
        Squishling.configure { |c| c.observer = observer }
        stub_llm(high)

        expect { klass.call(text: "x") }.to raise_error(error.class) { |e| expect(e).to equal(error) }
      end
    end

    it "gets the request's token usage and model back from the yield, not the response" do
      seen = []
      observer = Object.new
      observer.define_singleton_method(:around) { |_call, &block| seen << block.call }
      Squishling.configure { |c| c.observer = observer }
      tokens = Struct.new(:input, :output).new(120, 34)
      stub_llm(FakeChat::Response.new(high, "claude-haiku-4-5", tokens))

      expect(klass.call(text: "x").priority).to eq("high")
      expect(seen).to eq([Squishling::Observer::Usage.new(input_tokens: 120, output_tokens: 34,
        model: "claude-haiku-4-5")])
    end

    it "reports unreported counts as nil, and ignores what the observer returns" do
      seen = []
      observer = Object.new
      observer.define_singleton_method(:around) do |_call, &block|
        seen << block.call
        :not_the_response
      end
      Squishling.configure { |c| c.observer = observer }
      stub_llm(high)

      expect(klass.call(text: "x").priority).to eq("high")
      expect(seen.first).to have_attributes(input_tokens: nil, output_tokens: nil)
    end

    it "reads usage off a real RubyLLM::Message and Judgment" do
      message = RubyLLM::Message.new(role: :assistant, content: "{}", model: "claude-haiku-4-5",
        input_tokens: 7, output_tokens: 3)
      judgment = RubyLLM::Judgment.new(answers: {}, model: "jev-latest")

      expect(Squishling::Observer.send(:usage, message))
        .to eq(Squishling::Observer::Usage.new(input_tokens: 7, output_tokens: 3, model: "claude-haiku-4-5"))
      expect(Squishling::Observer.send(:usage, judgment))
        .to have_attributes(model: "jev-latest", input_tokens: nil, output_tokens: nil)
    end

    it "raises the request's error again when the observer rescues it" do
      observer = Object.new
      observer.define_singleton_method(:around) do |_call, &block|
        block.call
      rescue StandardError
        nil
      end
      Squishling.configure { |c| c.observer = observer }
      stub_llm(RubyLLM::ServerError.new("down"), RubyLLM::ServerError.new("down"))

      expect { klass.call(text: "x") }.to raise_error(Squishling::LLMError)
    end

    it "gives a System One judge's observer its usage too" do
      seen = []
      observer = Object.new
      observer.define_singleton_method(:around) { |call, &block| seen << [call.request, block.call] }
      Squishling.configure { |c| c.observer = observer }
      klass.squishling(harness: { type: :judged_squishsum,
                                  judge: { model: "jev-latest", type: :judgment, min_confidence: 0.8 } })
      stub_llm_chats([high], [low])
      stub_judgment({ choice: :a, probabilities: { a: 0.9, b: 0.05, neither: 0.05 } })

      klass.call(text: "x")

      expect(seen.last).to match([:judgment, an_instance_of(Squishling::Observer::Usage)])
    end

    it "raises ConfigurationError, sending one request, when it yields twice" do
      observer = Object.new
      observer.define_singleton_method(:around) { |_call, &block| [block.call, block.call] }
      Squishling.configure { |c| c.observer = observer }
      chats = stub_llm(high, high)

      expect { klass.call(text: "x") }.to raise_error(Squishling::ConfigurationError, /must yield only once/)
      expect(chats.sum { |chat| chat.messages.size }).to eq(1)
    end

    it "raises ConfigurationError even when the observer rescues the second yield" do
      observer = Object.new
      observer.define_singleton_method(:around) do |_call, &block|
        block.call
        begin
          block.call
        rescue StandardError
          nil
        end
      end
      Squishling.configure { |c| c.observer = observer }
      stub_llm(high, high)

      expect { klass.call(text: "x") }.to raise_error(Squishling::ConfigurationError, /must yield only once/)
    end

    it "raises ConfigurationError when it never yields" do
      observer = Object.new
      observer.define_singleton_method(:around) { |_call, &_block| nil }
      Squishling.configure { |c| c.observer = observer }
      stub_llm(high)

      expect { klass.call(text: "x") }
        .to raise_error(Squishling::ConfigurationError, /TicketTriage#call: .* around must yield/)
    end

    it "leaves failed requests mapped onto Squishling's errors" do
      stub_llm(RubyLLM::ServerError.new("provider down"), RubyLLM::ServerError.new("provider down"))

      expect { klass.call(text: "x") }.to raise_error(Squishling::LLMError)
      expect(events.map(&:first)).to eq(%i[before before])
    end

    it "names the harness of a custom one" do
      Squishling.register_harness(:once) do
        def call(run)
          run.escalate
        end
      end
      klass.squishling(harness: :once)
      stub_llm(high)

      klass.call(text: "x")

      expect(calls.map(&:harness)).to eq([:once])
    end

    it "is skipped on the deterministic path" do
      klass.squish_when { false }
      klass.define_method(:call) { |text:| result(priority: "low", team: text) }

      klass.call(text: "x")

      expect(events).to be_empty
    end

    it "is off with observer = false even when Coolhand is configured" do
      stub_const("Coolhand", Module.new)
      Squishling.configure { |c| c.observer = false }
      stub_llm(high)

      klass.call(text: "x")

      expect(events).to be_empty
    end
  end

  describe "the harnesses" do
    before { Squishling.configure { |c| c.observer = recorder } }

    it "names samples a and b and wraps each on the worker thread that makes the request" do
      klass.squishling(harness: :squishsum)
      ask_threads = Queue.new
      stub_llm_chats([high], [high], on_ask: ->(_) { ask_threads << Thread.current })

      klass.call(text: "x")

      sampled = events.select { |kind, call, _| kind == :before && call.role == :sample }
      expect(sampled.map { |_, call, _| call.sample }).to contain_exactly("a", "b")
      expect(sampled.map { |_, call, _| call.attempt }).to all(eq(1))
      expect(sampled.map { |_, _, thread| thread }).to all(satisfy { |thread| !thread.equal?(Thread.current) })
      expect(sampled.map { |_, _, thread| thread }).to match_array(Array.new(ask_threads.size) { ask_threads.pop })
    end

    it "propagates an observer's exception from a sample's worker thread, past the fallback" do
      boom = Class.new(StandardError)
      observer = Object.new
      observer.define_singleton_method(:around) { |_call, &_block| raise boom, "observer broke" }
      Squishling.configure { |c| c.observer = observer }
      klass.squishling(harness: :squishsum)
      klass.squish_fallback { |**| raise "fallback must not run" }
      stub_llm_chats([high], [high])

      expect { klass.call(text: "x") }.to raise_error(boom, "observer broke")
    end

    it "names a chat judge" do
      klass.squishling(harness: :judged_squishsum)
      stub_llm_chats([high], [low], [{ "verdict" => "a", "reason" => "outage" }])

      klass.call(text: "x")

      expect(calls.map(&:role)).to contain_exactly(:sample, :sample, :judge)
      judge = calls.find { |call| call.role == :judge }
      expect(judge).to have_attributes(harness: :judged_squishsum, model: "claude-sonnet-5-5", request: :chat,
        attempt: 1, attempts: 1)
    end

    it "counts a multi-step judge's attempts" do
      klass.squishling(harness: { type: :judged_squishsum, judge: { model: "claude-opus-5-5", attempts: 2 } })
      stub_llm_chats([high], [low], [{ "verdict" => "x", "reason" => "r" }, { "verdict" => "a", "reason" => "r" }])

      klass.call(text: "x")

      judged = calls.select { |call| call.role == :judge }
      expect(judged.map { |call| [call.attempt, call.attempts] }).to eq([[1, 2], [2, 2]])
    end

    it "names a System One judge, wrapped on the calling thread" do
      klass.squishling(harness: { type: :judged_squishsum,
                                  judge: { model: "jev-latest", type: :judgment, min_confidence: 0.8 } })
      stub_llm_chats([high], [low])
      stub_judgment({ choice: :a, probabilities: { a: 0.9, b: 0.05, neither: 0.05 } })

      klass.call(text: "x")

      judge = calls.find { |call| call.role == :judge }
      expect(judge).to have_attributes(model: "jev-latest", request: :judgment, harness: :judged_squishsum)
      expect(events.find { |_, call, _| call.role == :judge }.last).to equal(Thread.current)
    end
  end
end
