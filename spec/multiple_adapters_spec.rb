# frozen_string_literal: true

require "squishling/testing"

RSpec.describe "multiple adapters" do
  let(:apple) { FakeAdapter.new }
  let(:claude) { FakeAdapter.new }
  let(:local) { FakeAdapter.new }
  let(:default) { FakeAdapter.new }

  let(:high) { { "priority" => "high" } }
  let(:bad) { { "priority" => 1 } }

  let(:klass) do
    Class.new do
      include Squishling

      squishling escalation: [{ model: "apple-fm", adapter: :apple }, { model: "sonnet", adapter: "claude" },
                              { model: "llama3.2", adapter: :local }]
      purpose "Triage the ticket."
      output_schema { string :priority }

      def self.to_s = "TicketTriage"
    end
  end

  def configure_adapters
    Squishling.configure do |config|
      config.adapter = default
      config.adapters = { apple:, claude:, local: }
    end
  end

  # Each adapter answers the given replies, in order; one that isn't asked fails the example.
  def answer(adapter, *replies)
    adapter.responses = replies
  end

  describe "routing a step to its adapter" do
    before { configure_adapters }

    it "sends each escalation step to the adapter it names, moving on after invalid output" do
      answer(apple, bad)
      answer(claude, bad)
      answer(local, high)

      expect(klass.call(text: "x").priority).to eq("high")

      expect(apple.chats.map(&:model)).to eq(%w[apple-fm])
      expect(claude.chats.map(&:model)).to eq(%w[sonnet])
      expect(local.chats.map(&:model)).to eq(%w[llama3.2])
      expect(default.chats).to be_empty
    end

    it "stops at the first adapter that returns valid output" do
      answer(apple, high)

      klass.call(text: "x")

      expect([claude, local, default].map(&:chats)).to all(be_empty)
    end

    it "tells the adapter the name it was configured under, and the default adapter none" do
      requests = []
      replies = [bad, high]
      [default, local].each do |adapter|
        adapter.responder = lambda { |request|
          requests << request
          replies.shift
        }
      end
      klass.squishling(escalation: ["plain", { model: "m", adapter: :local }])

      klass.call(text: "x")

      expect(requests.map(&:adapter)).to eq([nil, :local])
    end

    it "uses the default adapter for a step that names none" do
      klass.squishling(escalation: ["plain", { model: "m", adapter: :local }])
      answer(default, bad)
      answer(local, high)

      expect(klass.call(text: "x").priority).to eq("high")
      expect(default.chats.map(&:model)).to eq(%w[plain])
      expect(local.chats.map(&:model)).to eq(%w[m])
    end

    it "retries in the same chat on the same adapter, then escalates to the next" do
      klass.squishling(escalation: [{ model: "apple-fm", adapter: :apple, attempts: 2 },
                                    { model: "sonnet", adapter: :claude }])
      answer(apple, bad, bad)
      answer(claude, high)

      klass.call(text: "x")

      expect(apple.chats.size).to eq(1)
      expect(apple.chats.first.messages.size).to eq(2)
      expect(claude.chats.size).to eq(1)
    end

    it "rotates the models of a tier between their adapters" do
      klass.squishling(escalation: [{ model: "a", adapter: :apple, priority: 1 },
                                    { model: "b", adapter: :claude, priority: 1 }])
      [apple, claude].each { |adapter| adapter.responder = ->(_) { high } }

      2.times { klass.call(text: "x") }

      expect(apple.chats.size).to eq(1)
      expect(claude.chats.size).to eq(1)
    end

    it "lets a squish! call pick an adapter for its own escalation" do
      parser = Class.new do
        include Squishling

        purpose "Parse the record."
        output_schema { string :priority }

        def call(record:)
          raise ArgumentError, record unless record.include?(",")
        rescue ArgumentError
          squish!(escalation: [{ model: "m", adapter: :local }])
        end
      end
      answer(local, high)

      expect(parser.call(record: "no comma").priority).to eq("high")
      expect(local.chats.map(&:model)).to eq(%w[m])
    end

    it "tells an observer which adapter each request went to" do
      seen = []
      observer = Object.new
      observer.define_singleton_method(:around) do |call, &block|
        seen << call.adapter
        block.call
      end
      Squishling.config.observer = observer
      answer(apple, bad)
      answer(claude, bad)
      answer(local, high)

      klass.call(text: "x")

      expect(seen).to eq(%i[apple claude local])
    end
  end

  describe "a name that isn't configured" do
    it "raises ConfigurationError naming the configured adapters, without a request" do
      configure_adapters
      klass.squishling(escalation: [{ model: "m", adapter: :cloud }])

      expect { klass.call(text: "x") }
        .to raise_error(Squishling::ConfigurationError,
          /unknown adapter :cloud \(configured: :apple, :claude, :local\)/)
    end

    it "is found before any step makes a request, even when it is the last" do
      configure_adapters
      klass.squishling(escalation: [{ model: "m", adapter: :apple }, { model: "n", adapter: :cloud }])

      expect { klass.call(text: "x") }.to raise_error(Squishling::ConfigurationError, /unknown adapter :cloud/)
      expect(apple.chats).to be_empty
    end

    it "says so when none are configured" do
      Squishling.config.adapter = default
      klass.squishling(escalation: [{ model: "m", adapter: :cloud }])

      expect { klass.call(text: "x") }
        .to raise_error(Squishling::ConfigurationError,
          /unknown adapter :cloud \(configured: none; set config.adapters/)
    end

    it "isn't tried by a fallback: a ConfigurationError ends the call" do
      configure_adapters
      klass.squishling(escalation: [{ model: "m", adapter: :cloud }])
      klass.squish_fallback { |_error, **| { priority: "fallback" } }

      expect { klass.call(text: "x") }.to raise_error(Squishling::ConfigurationError)
    end
  end

  describe "declaring adapter:" do
    it "takes a Symbol or String name, kept as a Symbol" do
      steps = Squishling::ModelPath.from_escalation([{ model: "m", adapter: "local" }, "n"], "X")

      expect(steps.map { |step| step[:adapter] }).to eq([:local, nil])
    end

    it "rejects anything else" do
      [5, true, " ", :""].each do |bad_name|
        expect { Squishling::ModelPath.from_escalation([{ model: "m", adapter: bad_name }], "X") }
          .to raise_error(Squishling::ConfigurationError, /adapter: must be the name of a configured adapter/)
      end
    end

    it "belongs to the step, so a provider: beside it is unchanged" do
      klass.squishling(escalation: [{ model: "m", provider: :openai, adapter: :local }])
      step = klass.squishling_definition(:call).escalation_path(klass.new, {}).first

      expect([step.provider, step.adapter]).to eq(%i[openai local])
    end
  end

  describe "config.adapters" do
    it "builds each adapter when assigned, like config.adapter" do
      Squishling.config.adapters = { local: { type: :openai_compatible, base_url: "http://localhost:11434/v1" } }

      expect(Squishling.config.adapter_for(:local)).to be_a(Squishling::Adapters::OpenAICompatible)
    end

    it "fails at setup for a mistake, naming the adapter" do
      expect { Squishling.config.adapters = { local: :nonesuch } }
        .to raise_error(Squishling::ConfigurationError, /adapters\[:local\] adapter: unknown adapter :nonesuch/)
      expect { Squishling.config.adapters = { local: { base_url: "x" } } }
        .to raise_error(Squishling::ConfigurationError, /needs a type:/)
      expect { Squishling.config.adapters = [:apple] }
        .to raise_error(Squishling::ConfigurationError, /adapters must be a Hash/)
      expect { Squishling.config.adapters = { 5 => apple } }
        .to raise_error(Squishling::ConfigurationError, /adapter name must be a Symbol/)
      expect { Squishling.config.adapters = { "apple" => apple, apple: claude } }
        .to raise_error(Squishling::ConfigurationError, /names :apple twice/)
    end

    it "keeps the previous adapters when an assignment fails, and clears them with nil" do
      Squishling.config.adapters = { apple: }
      expect { Squishling.config.adapters = { apple:, local: :nonesuch } }.to raise_error(Squishling::ConfigurationError)

      expect(Squishling.config.adapters.keys).to eq([:apple])
      Squishling.config.adapters = nil
      expect(Squishling.config.adapters).to be_empty
    end

    it "needs no default adapter when every step names one" do
      Squishling.config.adapters = { apple:, claude:, local: }
      allow(Squishling::Adapter).to receive(:detect).and_raise(Squishling::ConfigurationError, "no default")
      answer(apple, high)

      expect(klass.call(text: "x").priority).to eq("high")
    end
  end

  describe "samples on worker threads" do
    let(:contexts) { Queue.new }

    before do
      configure_adapters
      klass.squishling(harness: :squishsum, escalation: [{ model: "apple-fm", adapter: :apple }])
      apple.define_singleton_method(:capture_context) { :apple_context }
      claude.define_singleton_method(:capture_context) { raise "claude was not asked to capture" }
      apple.responder = lambda { |_request|
        contexts << Thread.current[:fake_adapter_context]
        high
      }
    end

    it "carries the step's own adapter's context, and captures none for adapters it doesn't use" do
      expect(klass.call(text: "x").priority).to eq("high")

      expect([contexts.pop, contexts.pop]).to eq(%i[apple_context apple_context])
    end

    it "gives each sample the context of its own adapter when the samples are on different ones" do
      Squishling.register_harness(:two_adapters) do
        define_method(:call) { |run| run.samples(run.stages.first(2)).first }
      end
      klass.squishling(harness: :two_adapters,
        escalation: [{ model: "apple-fm", adapter: :apple }, { model: "sonnet", adapter: :claude }])
      claude.define_singleton_method(:capture_context) { :claude_context }
      seen = Queue.new
      { apple: apple, claude: claude }.each do |name, adapter|
        adapter.responder = lambda { |_request|
          seen << [name, Thread.current[:fake_adapter_context]]
          high
        }
      end

      klass.call(text: "x")

      expect([seen.pop, seen.pop]).to contain_exactly(%i[apple apple_context], %i[claude claude_context])
    end
  end

  describe "a chat judge on another adapter" do
    let(:judges) { FakeAdapter.new }
    let(:low) { { "priority" => "low" } }
    let(:verdict) { { "verdict" => "b", "reason" => "routine ticket" } }

    before do
      Squishling.configure do |config|
        config.adapter = default
        config.adapters = { judges: }
      end
    end

    it "asks the judge on its own adapter" do
      klass.squishling(escalation: ["m"],
        harness: { type: :judged_squishsum, judge: { model: "judge-model", adapter: :judges } })
      replies = [high, low]
      default.responder = ->(_) { replies.shift }
      judges.responder = ->(_) { verdict }

      expect(klass.call(text: "x").priority).to eq("low")
      expect(judges.chats.map(&:model)).to eq(%w[judge-model])
      expect(default.chats.size).to eq(2)
    end

    it "is refused for an unknown adapter before any sample is requested" do
      klass.squishling(escalation: ["m"],
        harness: { type: :judged_squishsum, judge: { model: "judge-model", adapter: :typo } })

      expect { klass.call(text: "x") }.to raise_error(Squishling::ConfigurationError, /unknown adapter :typo/)
      expect(default.chats).to be_empty
    end

    it "is refused for a custom harness's stage on an unknown adapter, before it makes a request" do
      Squishling.register_harness(:typo_stage) do
        define_method(:call) { |run| run.escalate({ model: "m", adapter: :typo }) }
      end
      klass.squishling(escalation: ["m"], harness: :typo_stage)

      expect { klass.call(text: "x") }.to raise_error(Squishling::ConfigurationError, /unknown adapter :typo/)
      expect(default.chats).to be_empty
    end
  end

  describe "a judge on another adapter" do
    let(:jev) { { model: "jev-latest", type: :judgment, adapter: :judges } }
    let(:judges) { FakeAdapter.new }
    let(:low) { { "priority" => "low" } }

    before do
      default.judgments_supported = false
      Squishling.configure do |config|
        config.adapter = default
        config.adapters = { judges: }
      end
      klass.squishling(escalation: ["m"], harness: { type: :judged_squishsum, judge: jev })
    end

    it "uses that adapter's judgments, though the default one has none" do
      replies = [high, low]
      default.responder = ->(_) { replies.shift }
      judges.judgments = [{ choice: :b, probabilities: { a: 0.05, b: 0.9, neither: 0.05 } }]

      expect(klass.call(text: "x").priority).to eq("low")
      expect(judges.judge_calls.map { |call| call[:options][:model] }).to eq(%w[jev-latest])
      expect(default.judge_calls).to be_empty
    end

    it "refuses a judge whose own adapter has no judgments, before any request" do
      judges.judgments_supported = false

      expect { klass.call(text: "x") }
        .to raise_error(Squishling::ConfigurationError, /judge type: :judgment needs an adapter that supports/)
      expect(default.chats).to be_empty
    end
  end

  describe "Squishling.verify" do
    before { Squishling::ClassRegistry.reset! }

    def messages(klass)
      Squishling.verify(klass).problems.map(&:to_s)
    end

    it "finds a step whose adapter isn't configured" do
      configure_adapters
      klass.squishling(escalation: ["ok", { model: "m", adapter: :cloud }])

      expect(messages(klass)).to contain_exactly(a_string_including("adapter: unknown adapter :cloud"))
    end

    it "finds a judge whose adapter isn't configured" do
      configure_adapters
      klass.squishling(escalation: ["m"], harness: { type: :judged_squishsum, judge: { model: "j", adapter: :cloud } })

      expect(messages(klass)).to include(a_string_including("adapter: unknown adapter :cloud"))
    end

    it "checks the default adapter for a judge that names none, when every step names an adapter" do
      Squishling.config.adapters = { local: }
      allow(Squishling::Adapter).to receive(:detect).and_raise(Squishling::ConfigurationError, "no default")
      klass.squishling(escalation: [{ model: "m", adapter: :local }],
        harness: { type: :judged_squishsum, judge: { model: "j" } })

      expect(messages(klass)).to contain_exactly(a_string_including("adapter: no default"))
    end

    it "is clean when every step's adapter is configured" do
      configure_adapters

      expect(Squishling.verify(klass)).to be_ok
    end

    it "reports a step on the default adapter when named adapters exist but the default can't be used" do
      Squishling.config.adapters = { local: }
      allow(Squishling::Adapter).to receive(:detect).and_raise(Squishling::ConfigurationError, "no default")
      klass.squishling(escalation: ["plain", { model: "m", adapter: :local }])

      expect(messages(klass)).to contain_exactly(a_string_including("adapter: no default"))
    end

    it "still finds an unknown name while Squishling::Testing routes every request to its adapter" do
      configure_adapters
      Squishling::Testing.install
      klass.squishling(escalation: [{ model: "m", adapter: :cloud }])

      expect(messages(klass)).to contain_exactly(a_string_including("adapter: unknown adapter :cloud"))
    ensure
      Squishling::Testing.reset!
    end

    it "makes no request" do
      configure_adapters
      [apple, claude, local, default].each do |adapter|
        expect(adapter).not_to receive(:complete)
        expect(adapter).not_to receive(:judge)
      end

      Squishling.verify(klass)
    end
  end

  describe "Squishling::Testing" do
    include Squishling::Testing::RSpec

    before { configure_adapters }

    it "answers for every adapter name, and records which one each step asked for" do
      llm = fake_squishling do |script|
        script.step(adapter: :apple).reply(bad)
        script.step(adapter: :claude).reply(bad)
        script.step(adapter: :local).reply(high)
      end

      expect(klass.call(text: "x").priority).to eq("high")

      expect(llm.requests.map(&:adapter)).to eq(%i[apple claude local])
      expect(llm.requests.map(&:model)).to eq(%w[apple-fm sonnet llama3.2])
    end

    it "names the adapter in an unscripted request" do
      fake_squishling { |script| script.step(adapter: :claude).reply(high) }

      expect { klass.call(text: "x") }
        .to raise_error(Squishling::Testing::UnscriptedRequestError, /adapter: :apple/)
    end

    it "forbids provider calls for every name" do
      forbid_provider_calls!

      expect { klass.call(text: "x") }.to raise_error(Squishling::Testing::ProviderCallError)
    end

    it "puts the adapters back afterwards" do
      Squishling::Testing.install
      Squishling::Testing.reset!

      expect(Squishling.config.adapter_override).to be_nil
      expect(Squishling.config.adapter_for(:apple)).to equal(apple)
    end

    it "forbids calls for the duration of no_llm_call, then restores both" do
      attempts = Squishling::Testing.no_llm_call { klass.call(text: "x") }

      expect(attempts).to eq(["TicketTriage#call"])
      expect(Squishling.config.adapter).to equal(default)
      expect(Squishling.config.adapter_override).to be_nil
    end
  end
end
