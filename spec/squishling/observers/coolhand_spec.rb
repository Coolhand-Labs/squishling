# frozen_string_literal: true

RSpec.describe Squishling::Observers::Coolhand do
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
  let(:declared) { [] }
  let(:settings) { Struct.new(:api_key, :enabled).new("key", true) }

  # Stand-in for the coolhand gem: records each declaration and the thread it was made on.
  let(:coolhand) do
    log = declared
    config = settings
    Module.new do
      define_singleton_method(:with_context) do |**context, &block|
        log << [context, Thread.current]
        block.call
      end
      define_singleton_method(:configuration) { config }
    end
  end

  def contexts
    declared.map(&:first)
  end

  describe "when Coolhand is configured and no observer is declared" do
    before { stub_const("Coolhand", coolhand) }

    it "declares the workload and the escalation level of each attempt" do
      stub_llm(bad, high)

      klass.call(text: "x")

      expect(contexts).to eq([
        { reporter: "squishling",
          workload: { key: "TicketTriage#call", name: "TicketTriage#call", description: "TicketTriage#call" },
          template: { key: "TicketTriage#call/squish:L1", name: "TicketTriage#call · squish L1" } },
        { reporter: "squishling",
          workload: { key: "TicketTriage#call", name: "TicketTriage#call", description: "TicketTriage#call" },
          template: { key: "TicketTriage#call/squish:L2", name: "TicketTriage#call · squish L2" } }
      ])
    end

    it "describes the workload as the method, not the purpose, however the purpose is computed" do
      klass.purpose { "Triage ticket #{rand(1_000_000)}." }
      stub_llm(high)

      klass.call(text: "x")

      expect(contexts.map { |context| context.dig(:workload, :description) }).to eq(["TicketTriage#call"])
    end

    it "marks the description (rescue) when squish! handed the call to the LLM, keeping one workload key" do
      klass.define_method(:call) do |text:|
        raise ArgumentError, "unparseable: #{text}"
      rescue ArgumentError
        squish!
      end
      stub_llm(high)

      expect(klass.call(text: "x").priority).to eq("high")
      expect(contexts.map { |context| context[:workload] }).to eq([
        { key: "TicketTriage#call", name: "TicketTriage#call", description: "TicketTriage#call (rescue)" }
      ])
    end

    it "yields once and returns the block's value from Coolhand.with_context" do
      call = Squishling::Observer::Call.new(label: "A#b", purpose: "p", harness: :escalation, handed_off: false,
        role: nil, sample: nil, attempt: 1, attempts: 1, model: "m", provider: nil, request: :chat)

      expect(described_class.new.around(call) { :response }).to eq(:response)
    end

    it "keeps the model out of the template key" do
      stub_llm(high)

      klass.call(text: "x")

      expect(contexts.first[:template].keys).to eq(%i[key name])
      expect(contexts.first[:template].values.join).not_to match(/haiku|sonnet/)
    end

    it "names the samples a and b, declared on the worker threads that make the requests" do
      klass.squishling(harness: :squishsum)
      asked = Queue.new
      stub_llm_chats([high], [high], on_ask: ->(_) { asked << Thread.current })

      klass.call(text: "x")

      expect(contexts.map { |context| context[:template] }).to contain_exactly(
        { key: "TicketTriage#call/sample:a", name: "TicketTriage#call · sample a" },
        { key: "TicketTriage#call/sample:b", name: "TicketTriage#call · sample b" }
      )
      threads = declared.map(&:last)
      expect(threads).not_to include(Thread.current)
      expect(threads).to match_array(Array.new(asked.size) { asked.pop })
    end

    it "names the judge, for a chat model and a System One model" do
      klass.squishling(harness: :judged_squishsum)
      stub_llm_chats([high], [low], [{ "verdict" => "a", "reason" => "outage" }])
      klass.call(text: "x")
      expect(contexts.last[:template]).to eq(key: "TicketTriage#call/judge", name: "TicketTriage#call · judge")

      declared.clear
      klass.squishling(harness: { type: :judged_squishsum, judge: { model: "jev-latest", type: :judgment } })
      stub_llm_chats([high], [low])
      stub_judgment({ choice: :a, probabilities: { a: 0.9, b: 0.05, neither: 0.05 } })
      klass.call(text: "x")
      expect(contexts.last[:template]).to eq(key: "TicketTriage#call/judge", name: "TicketTriage#call · judge")
    end

    it "doesn't declare when observer is false" do
      Squishling.configure { |c| c.observer = false }
      stub_llm(high)

      klass.call(text: "x")

      expect(declared).to be_empty
    end

    it "doesn't break the call over a key Coolhand would reject" do
      ["A" * 300, " Padded", "Doubled//Slash", "/Leading"].each do |name|
        rejected = Class.new(klass).tap { |subclass| subclass.define_singleton_method(:to_s) { name } }
        stub_llm(high)

        expect(rejected.call(text: "x").priority).to eq("high")
      end
      expect(declared).to be_empty
    end
  end

  describe "when Coolhand isn't ready" do
    it "doesn't declare without an api key" do
      stub_const("Coolhand", coolhand)
      settings.api_key = " "
      stub_llm(high)

      klass.call(text: "x")

      expect(declared).to be_empty
    end

    it "doesn't declare when Coolhand is disabled" do
      stub_const("Coolhand", coolhand)
      settings.enabled = false
      stub_llm(high)

      klass.call(text: "x")

      expect(declared).to be_empty
    end

    it "doesn't declare, or break the call, when Coolhand can't report its configuration" do
      stub_const("Coolhand", Module.new do
        def self.with_context(**) = yield
        def self.configuration = Object.new
      end)
      stub_llm(high)

      expect(klass.call(text: "x").priority).to eq("high")
    end

    it "doesn't declare with a Coolhand that can't declare workloads" do
      stub_const("Coolhand", Module.new { def self.configuration = Struct.new(:api_key, :enabled).new("k", true) })
      stub_llm(high)

      expect(klass.call(text: "x").priority).to eq("high")
    end
  end

  describe "observer = :coolhand" do
    it "declares even without an api key" do
      stub_const("Coolhand", coolhand)
      settings.api_key = nil
      Squishling.configure { |c| c.observer = :coolhand }
      stub_llm(high)

      klass.call(text: "x")

      expect(contexts.size).to eq(1)
    end

    it "raises a clear ConfigurationError at setup when the gem is missing" do
      hide_const("Coolhand")
      allow(described_class).to receive(:load_library).and_raise(LoadError)

      expect { Squishling.configure { |c| c.observer = :coolhand } }
        .to raise_error(Squishling::ConfigurationError, /needs the coolhand gem/)
    end

    it "raises a clear ConfigurationError at setup when the gem can't declare workloads" do
      stub_const("Coolhand", Module.new)

      expect { Squishling.configure { |c| c.observer = :coolhand } }
        .to raise_error(Squishling::ConfigurationError, /Coolhand\.with_context/)
    end
  end
end
