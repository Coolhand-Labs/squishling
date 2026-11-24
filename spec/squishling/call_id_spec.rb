# frozen_string_literal: true

require "squishling/testing"

RSpec.describe Squishling::CallId do
  let(:events) { [] }
  let(:squawked) { [] }
  let(:uuid) { /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/ }
  let(:klass) do
    log = squawked
    Class.new do
      include Squishling

      squishling escalation: ["claude-haiku-4-5", "claude-sonnet-5-5"], squawk: ->(metadata:, **) { log << metadata }
      purpose "Triage the ticket."
      output_schema do
        string :priority
      end

      def self.to_s = "TicketTriage"
    end
  end
  let(:high) { { "priority" => "high" } }
  let(:bad) { { "priority" => 1 } }

  before do
    log = events
    observer = Object.new
    observer.define_singleton_method(:around) do |call, &block|
      log << call
      block.call
    end
    Squishling.configure { |config| config.observer = observer }
  end

  describe "a call inside the block" do
    it "uses the id, and numbers its requests under it" do
      stub_llm(bad, high)

      Squishling.with_call_id("ticket-123") { klass.call }

      expect(events.map(&:call_id)).to eq(%w[ticket-123 ticket-123])
      expect(events.map(&:request_id)).to eq(%w[ticket-123.1 ticket-123.2])
    end

    it "returns the block's value" do
      stub_llm(high)

      expect(Squishling.with_call_id("ticket-123") { klass.call }.priority).to eq("high")
    end

    it "reaches squawk's metadata" do
      stub_llm(high)

      Squishling.with_call_id("ticket-123") { klass.call }

      expect(squawked).to all(include(call_id: "ticket-123"))
    end

    it "names only the first call: a second one gets its own id" do
      stub_llm(high, high)

      Squishling.with_call_id("ticket-123") do
        klass.call
        klass.call
      end

      expect(events.map(&:call_id).first).to eq("ticket-123")
      expect(events.map(&:call_id).last).to match(uuid)
      expect(events.map(&:request_id)).to eq(events.map { |call| "#{call.call_id}.1" })
    end

    it "names the outer call, not one it makes: a nested call gets its own id" do
      inner = klass
      outer = Class.new do
        include Squishling

        squishling model: "test-model"
        purpose "Outer."
        output_schema { string :priority }
        define_method(:call) { inner.call.to_h }
      end
      stub_llm(high, high)

      Squishling.with_call_id("ticket-123") { outer.new.call }

      expect(events.map(&:call_id).first).to match(uuid)
      expect(events.map(&:call_id).uniq).not_to include("ticket-123")
    end

    it "is kept by a first call that only runs Ruby, so a later call gets its own id" do
      ruby_only = Class.new do
        include Squishling

        squishling model: "test-model"
        purpose "Ruby only."
        output_schema { string :priority }
        def call = result(priority: "low")
      end
      stub_llm(high)

      Squishling.with_call_id("ticket-123") do
        expect(ruby_only.new.call.priority).to eq("low")
        klass.call
      end

      expect(events.map(&:call_id).first).to match(uuid)
    end

    it "is used by a squish! hand-off" do
      klass.send(:define_method, :call) { squish! }
      stub_llm(high)

      Squishling.with_call_id("ticket-123") { klass.new.call }

      expect(events.map(&:call_id)).to eq(["ticket-123"])
    end
  end

  describe "the scope" do
    it "ends with the block, including when it raises" do
      stub_llm(high)

      expect { Squishling.with_call_id("ticket-123") { raise "boom" } }.to raise_error("boom")
      klass.call

      expect(events.first.call_id).to match(uuid)
    end

    it "keeps an enclosing scope when a nested id is refused" do
      stub_llm(high)

      Squishling.with_call_id("outer") do
        expect { Squishling.with_call_id("") { nil } }.to raise_error(Squishling::ConfigurationError)
        klass.call
      end

      expect(events.map(&:call_id)).to eq(["outer"])
    end

    it "is not seen from a fiber the block starts" do
      stub_llm(high)

      Squishling.with_call_id("ticket-123") { Fiber.new { klass.call }.resume }

      expect(events.first.call_id).to match(uuid)
    end

    it "nests, the inner id winning inside it and the outer one resuming after" do
      stub_llm(high, high)

      Squishling.with_call_id("outer") do
        Squishling.with_call_id("inner") { klass.call }
        klass.call
      end

      expect(events.map(&:call_id)).to eq(%w[inner outer])
    end

    it "is not seen from another thread" do
      stub_llm(high)

      Squishling.with_call_id("ticket-123") { Thread.new { klass.call }.join }

      expect(events.first.call_id).to match(uuid)
    end
  end

  describe "a bad id" do
    it "raises ConfigurationError before anything runs" do
      bad = ["", "  ", " padded", "line\nbreak", "a\u2028b", "zero\u200Bwidth", "\xff", "caf\u00e9".b,
             "nb\u00a0sp\u00a0", "\u3000x", "x" * 251, :symbol, 12, nil]
      bad.each do |id|
        expect { Squishling.with_call_id(id) { raise "ran" } }.to raise_error(Squishling::ConfigurationError)
      end
    end

    it "takes an id in another encoding as UTF-8" do
      stub_llm(high)

      Squishling.with_call_id("ticket".encode("UTF-16LE")) { klass.call }

      expect(events.first.call_id).to eq("ticket")
      expect(events.first.call_id.encoding).to eq(Encoding::UTF_8)
    end

    it "takes the longest id that leaves room for the request number" do
      id = "x" * 250
      stub_llm(high)

      Squishling.with_call_id(id) { klass.call }

      expect(events.first.request_id).to eq("#{id}.1")
    end

    it "needs a block" do
      expect { Squishling.with_call_id("ticket-123") }.to raise_error(Squishling::ConfigurationError, /block/)
    end
  end

  describe "an apprentice's shadow run" do
    let(:reports) { [] }
    let(:klass) do
      hook = ->(**report) { reports << report }
      Class.new do
        include Squishling

        squishling model: "test-model", apprentice: { report: hook }
        purpose "Classify the ticket."
        output_schema do
          string :priority
        end

        def self.to_s = "Triage"

        def call = { priority: "high" }
      end
    end

    it "reports the id even when the shadow run ends before it makes a request" do
      hook = ->(**report) { reports << report }
      klass.squishling(apprentice: { when: ->(**) { raise KeyError, "no sampler" }, report: hook })

      Squishling.with_call_id("ticket-123") { klass.call }

      expect(reports.first[:metadata]).to include(call_id: "ticket-123", request_id: nil)
    end

    it "uses the id even when the shadow run happens on another thread" do
      Squishling.configure { |config| config.apprentice_runner = ->(job) { Thread.new(&job).join } }
      stub_llm(high)

      Squishling.with_call_id("ticket-123") { klass.call }

      expect(events.map(&:request_id)).to eq(["ticket-123.1"])
      expect(reports.first[:metadata]).to include(call_id: "ticket-123", request_id: "ticket-123.1")
    end
  end
end
