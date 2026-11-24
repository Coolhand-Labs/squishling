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

  describe "a declared call_id:" do
    let(:declared) do
      Class.new do
        include Squishling

        squishling model: "test-model", call_id: :record_id
        purpose "Triage the record."
        output_schema { string :priority }

        def self.to_s = "RecordTriage"

        def call(record_id:, note: nil) = squish!(context: { record_id:, note: })
      end
    end
    let(:logged) { StringIO.new }

    before do
      Squishling::CallId.reset!
      Squishling.configure { |config| config.logger = Logger.new(logged, level: Logger::WARN) }
    end

    it "takes each call's id from the named input" do
      stub_llm(high, high)

      declared.call(record_id: "rec-1")
      declared.call(record_id: "rec-2")

      expect(events.map(&:request_id)).to eq(%w[rec-1.1 rec-2.1])
    end

    it "takes a non-String input (an Integer, a Symbol) as its text, and a nil one as no declaration" do
      stub_llm(high, high, high)

      declared.call(record_id: 42)
      declared.call(record_id: :sym)
      declared.call(record_id: nil)

      expect(events.map(&:call_id).first(2)).to eq(%w[42 sym])
      expect(events.last.call_id).to match(uuid)
    end

    it "takes a Proc, which gets the inputs, for an id built from several" do
      declared.squishling(call_id: ->(record_id:, note:) { "#{record_id}-#{note}" })
      stub_llm(high)

      declared.call(record_id: "rec-1", note: "a")

      expect(events.first.call_id).to eq("rec-1-a")
    end

    it "is overridden by a method's own declaration, and turned off by false" do
      declared.squish(:call, call_id: ->(record_id:, **) { "m-#{record_id}" })
      stub_llm(high)
      declared.call(record_id: "rec-1")
      declared.squish(:call, call_id: false)
      stub_llm(high)
      declared.call(record_id: "rec-1")

      expect(events.map(&:call_id).first).to eq("m-rec-1")
      expect(events.map(&:call_id).last).to match(uuid)
    end

    it "is inherited by a subclass" do
      stub_llm(high)

      Class.new(declared).call(record_id: "rec-1")

      expect(events.first.call_id).to eq("rec-1")
    end

    it "yields to Squishling.with_call_id for the call that block names" do
      stub_llm(high, high)

      Squishling.with_call_id("ticket-123") do
        declared.call(record_id: "rec-1")
        declared.call(record_id: "rec-2")
      end

      expect(events.map(&:call_id)).to eq(%w[ticket-123 rec-2])
    end

    it "is used by an apprentice's shadow run" do
      shadowed = Class.new do
        include Squishling

        squishling model: "test-model", call_id: :record_id, apprentice: true
        purpose "Triage the record."
        output_schema { string :priority }
        def call(record_id:) = result(priority: record_id.empty? ? "low" : "high")
      end
      stub_llm(high)

      shadowed.call(record_id: "rec-1")

      expect(events.map(&:request_id)).to eq(["rec-1.1"])
    end

    it "raises ConfigurationError for an input that isn't an acceptable id, before any request" do
      stub_llm(high)

      expect { declared.call(record_id: " padded ") }
        .to raise_error(Squishling::ConfigurationError, /RecordTriage#call call_id: needs a String/)
      expect(events).to be_empty
    end

    it "refuses a declaration that is neither an input name, a Proc nor false" do
      expect { declared.squishling(call_id: "record_id") }.to raise_error(Squishling::ConfigurationError, /call_id:/)
      expect { declared.squish(:call, call_id: 5) }.to raise_error(Squishling::ConfigurationError, /call_id:/)
    end

    it "is checked by Squishling.verify against the method's inputs" do
      declared.squishling(call_id: :nope)
      problems = Squishling.verify(declared).problems.map(&:message)

      expect(problems).to include(a_string_matching(/call_id: names :nope.*inputs: record_id, note/))

      declared.squishling(call_id: ->(wrong:) { wrong })
      expect(Squishling.verify(declared).problems.map(&:message)).to include(a_string_matching(/call_id:/))

      declared.squishling(call_id: :record_id)
      expect(Squishling.verify(declared)).to be_ok
    end

    it "reads a positional input too" do
      positional = Class.new do
        include Squishling

        squishling model: "test-model", call_id: :record_id
        purpose "Triage the record."
        output_schema { string :priority }
        def call(record_id) = squish!(context: { record_id: })
      end
      stub_llm(high)

      positional.call("rec-9")

      expect(events.first.call_id).to eq("rec-9")
    end

    it "isn't read by a Ruby-only call, or by the call a with_call_id block names" do
      reads = []
      declared.squishling(call_id: ->(record_id:, **) { (reads << record_id) && record_id })
      declared.class_eval do
        def call(record_id:, note: nil)
          note == "ruby" ? result(priority: record_id.size > 100 ? "high" : "low") : squish!(context: { record_id: })
        end
      end
      stub_llm(high)

      declared.call(record_id: "ruby-only", note: "ruby")
      Squishling.with_call_id("ticket-123") { declared.call(record_id: "named") }

      expect(reads).to be_empty
    end

    it "lets a subclass override an inherited declaration, or turn it off" do
      stub_llm(high, high)

      Class.new(declared) { squishling call_id: ->(record_id:, **) { "sub-#{record_id}" } }.call(record_id: "1")
      Class.new(declared) { squishling call_id: false }.call(record_id: "1")

      expect(events.first.call_id).to eq("sub-1")
      expect(events.last.call_id).to match(uuid)
    end

    it "does not leave a Proc's own error to squish_fallback, or wrap it" do
      declared.squishling(call_id: ->(**) { raise KeyError, "no id" })
      declared.squish_fallback { |_error, **| { priority: "fallback" } }
      stub_llm(high)

      expect { declared.call(record_id: "rec-1") }.to raise_error(KeyError, "no id")
    end

    it "is flagged by Squishling.verify for a class's method that lacks the input, which needs its own declaration" do
      two = Class.new do
        include Squishling

        squishling model: "test-model", call_id: :record_id
        purpose "Triage."
        output_schema { string :priority }
        def call(record_id:) = squish!(context: { record_id: })
        def other(text:) = squish!(context: { text: })
        squish :other
      end

      expect(Squishling.verify(two).problems.map(&:message)).to include(a_string_matching(/not an input of the method/))

      two.squish :other, call_id: false
      expect(Squishling.verify(two)).to be_ok
    end

    it "keeps an apprentice's shadow run from raising when the declared id is unusable" do
      shadowed = Class.new do
        include Squishling

        squishling model: "test-model", apprentice: true, call_id: ->(**) { raise KeyError, "no id" }
        purpose "Triage."
        output_schema { string :priority }
        def call = result(priority: "high")
      end
      reported = []
      shadowed.squishling(apprentice: { report: ->(error:, metadata:, **) { reported << [error, metadata] } })
      stub_llm(high)

      expect(shadowed.call.priority).to eq("high")
      expect(reported.first.first).to be_a(KeyError)
      expect(events).to be_empty
    end

    it "warns once per method, never naming the id, when a declared id comes up again" do
      stub_llm(high, high, high)

      3.times { declared.call(record_id: "rec-1") }

      expect(logged.string.scan("RecordTriage#call call_id:").size).to eq(1)
      expect(logged.string).not_to include("rec-1")
    end

    it "doesn't warn for ids that differ" do
      stub_llm(high, high)

      declared.call(record_id: "rec-1")
      declared.call(record_id: "rec-2")

      expect(logged.string).to be_empty
    end
  end
end
