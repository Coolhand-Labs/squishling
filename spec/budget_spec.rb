# frozen_string_literal: true

require "logger"
require "stringio"

RSpec.describe "Squishling token budget" do
  # Two steps of two attempts: up to four requests per call.
  let(:klass) do
    Class.new do
      include Squishling

      squishling escalation: [{ model: "claude-haiku-4-5", attempts: 2 }, { model: "claude-sonnet-5-5", attempts: 2 }]
      purpose "Classify."
      output_schema { string :label }
    end
  end

  # A response that fails the schema (label must be a String), or passes it, with the tokens it used.
  def invalid(output: 10_000, input: 100)
    FakeChat::Response.new({ "label" => 1 }, nil, { input_tokens: input, output_tokens: output })
  end

  def valid(output: 10_000, input: 100)
    FakeChat::Response.new({ "label" => "ok" }, nil, { input_tokens: input, output_tokens: output })
  end

  describe "stopping an escalation" do
    it "stops before the next attempt once the output tokens used reach the budget" do
      klass.squishling(max_total_output_tokens: 25_000)
      stub_llm(invalid, invalid, invalid, invalid)

      expect { klass.call(text: "x") }.to raise_error(Squishling::BudgetExhaustedError) { |error|
        expect(error).to be_a(Squishling::InvalidOutputError)
        expect(error.limit).to eq(:max_total_output_tokens)
        expect(error.max).to eq(25_000)
        expect(error.used).to eq(input_tokens: 300, output_tokens: 30_000)
        expect(error.attempts).to eq(3)
        expect(error.models).to eq(%w[claude-haiku-4-5 claude-haiku-4-5 claude-sonnet-5-5])
        expect(error.raw).to eq({ "label" => 1 })
        expect(error.errors.first).to eq("token budget exhausted: 30000 of 25000 max_total_output_tokens used")
        expect(error.errors.size).to be > 1
      }
    end

    it "makes every attempt, and raises a plain InvalidOutputError, with no budget" do
      stub_llm(invalid, invalid, invalid, invalid)

      expect { klass.call(text: "x") }.to raise_error(Squishling::InvalidOutputError) { |error|
        expect(error).not_to be_a(Squishling::BudgetExhaustedError)
        expect(error.attempts).to eq(4)
      }
    end

    it "counts a budget as spent when the tokens used equal it, not only when they pass it" do
      klass.squishling(max_total_output_tokens: 20_000)
      chats = stub_llm(invalid, invalid, invalid, invalid)

      expect { klass.call(text: "x") }.to raise_error(Squishling::BudgetExhaustedError) { |error|
        expect(error.attempts).to eq(2)
        expect(error.used).to eq(input_tokens: 200, output_tokens: 20_000)
      }
      expect(chats.map { |chat| chat.messages.size }).to eq([2])
    end

    it "stops at the input budget too" do
      klass.squishling(max_total_input_tokens: 150)
      chats = stub_llm(invalid, invalid, invalid, invalid)

      expect { klass.call(text: "x") }
        .to raise_error(Squishling::BudgetExhaustedError, /200 of 150 max_total_input_tokens/)
      expect(chats.map { |chat| chat.messages.size }).to eq([2])
    end

    it "always makes the first request, and returns an output accepted within the budget" do
      klass.squishling(max_total_output_tokens: 1)
      stub_llm(valid)

      expect(klass.call(text: "x").label).to eq("ok")
    end

    it "stops after a single attempt when that one spent the budget, even if the next would have failed" do
      klass.squishling(max_total_output_tokens: 5_000, escalation: ["claude-haiku-4-5", "claude-sonnet-5-5"])
      chats = stub_llm(invalid, Squishling::LLMError.new("rate limited"))

      expect { klass.call(text: "x") }.to raise_error(Squishling::BudgetExhaustedError) { |error|
        expect(error.attempts).to eq(1)
        expect(error.models).to eq(["claude-haiku-4-5"])
      }
      expect(chats.size).to eq(1)
    end

    it "never stops a call whose provider reports no token counts" do
      klass.squishling(max_total_output_tokens: 1)
      stub_llm({ "label" => 1 }, { "label" => 1 }, { "label" => 1 }, { "label" => "ok" })

      expect(klass.call(text: "x").label).to eq("ok")
    end

    it "counts each call on its own" do
      klass.squishling(max_total_output_tokens: 15_000)
      stub_llm(invalid, valid, invalid, valid)

      expect(klass.call(text: "x").label).to eq("ok")
      expect(klass.call(text: "x").label).to eq("ok")
    end

    it "logs why it stopped, without the model's output" do
      log = StringIO.new
      Squishling.config.logger = Logger.new(log)
      klass.squishling(max_total_output_tokens: 5_000)
      stub_llm(invalid, invalid)

      expect { klass.call(text: "x") }.to raise_error(Squishling::BudgetExhaustedError)
      expect(log.string).to include("token budget exhausted: 10000 of 5000 max_total_output_tokens used")
    end

    it "hands the error to squish_fallback" do
      klass.squishling(max_total_output_tokens: 5_000)
      klass.squish_fallback { |error, **| { label: error.class.name } }
      stub_llm(invalid, invalid)

      result = klass.call(text: "x")

      expect(result.label).to eq("Squishling::BudgetExhaustedError")
      expect(result).not_to be_squished
    end
  end

  describe "declaring a budget" do
    before { stub_llm(invalid, invalid, invalid, invalid) }

    def attempts_made
      klass.call(text: "x")
    rescue Squishling::InvalidOutputError => e
      e.attempts
    end

    it "takes the configured default" do
      Squishling.config.default_max_total_output_tokens = 15_000

      expect(attempts_made).to eq(2)
    end

    it "lets the class override the configured limit" do
      Squishling.config.default_max_total_output_tokens = 15_000
      klass.squishling(max_total_output_tokens: 35_000)

      expect(attempts_made).to eq(4)
    end

    it "lets a method override the class, limit by limit" do
      klass.squishling(max_total_output_tokens: 35_000, max_total_input_tokens: 250)
      klass.squish :call, max_total_output_tokens: 15_000

      error = begin
        klass.call(text: "x")
      rescue Squishling::BudgetExhaustedError => e
        e
      end

      expect(error.limit).to eq(:max_total_output_tokens)
      expect(error.attempts).to eq(2)
    end

    it "inherits a parent class's budget" do
      klass.squishling(max_total_output_tokens: 15_000)

      child = Class.new(klass)

      expect { child.call(text: "x") }.to raise_error(Squishling::BudgetExhaustedError) { |error|
        expect(error.attempts).to eq(2)
      }
    end

    it "lifts a limit that is inherited with false" do
      klass.squishling(max_total_output_tokens: 15_000)
      klass.squish :call, max_total_output_tokens: false

      expect(attempts_made).to eq(4)
    end

    it "is replaced for one call by squish!" do
      handing_off = Class.new do
        include Squishling

        squishling escalation: [{ model: "claude-haiku-4-5", attempts: 2 }], max_total_output_tokens: 50_000
        purpose "Classify."
        output_schema { string :label }

        def call(text:)
          raise NotImplementedError, text
        rescue NotImplementedError
          squish!(max_total_output_tokens: 5_000)
        end
      end

      expect { handing_off.call(text: "x") }.to raise_error(Squishling::BudgetExhaustedError) { |error|
        expect(error.max).to eq(5_000)
      }
    end

    it "lifts a limit for one squish! call with false" do
      handing_off = Class.new do
        include Squishling

        squishling escalation: [{ model: "claude-haiku-4-5", attempts: 2 }], max_total_output_tokens: 5_000
        purpose "Classify."
        output_schema { string :label }

        def call(text:)
          raise NotImplementedError, text
        rescue NotImplementedError
          squish!(max_total_output_tokens: false)
        end
      end

      expect { handing_off.call(text: "x") }
        .to raise_error(Squishling::InvalidOutputError) { |error|
          expect(error).not_to be_a(Squishling::BudgetExhaustedError)
          expect(error.attempts).to eq(2)
        }
    end

    it "rejects a bad squish! limit" do
      handing_off = Class.new do
        include Squishling

        squishling model: "claude-haiku-4-5"
        purpose "Classify."
        output_schema { string :label }

        def call(text:)
          raise NotImplementedError, text
        rescue NotImplementedError
          squish!(max_total_input_tokens: 0)
        end
      end

      expect { handing_off.call(text: "x") }
        .to raise_error(Squishling::ConfigurationError, /max_total_input_tokens must be a positive Integer/)
    end

    it "clears a configured default with nil" do
      Squishling.config.default_max_total_output_tokens = 15_000
      Squishling.config.default_max_total_output_tokens = nil

      expect(attempts_made).to eq(4)
    end

    it "lets a subclass override its parent's limit" do
      klass.squishling(max_total_output_tokens: 15_000)
      child = Class.new(klass)
      child.squishling(max_total_output_tokens: 35_000)

      expect { child.call(text: "x") }.to raise_error(Squishling::InvalidOutputError) { |error|
        expect(error).not_to be_a(Squishling::BudgetExhaustedError)
        expect(error.attempts).to eq(4)
      }
    end

    it "rejects a limit that isn't a positive Integer" do
      ["10", 0, -5, 1.5, true].each do |bad|
        expect { klass.squishling(max_total_output_tokens: bad) }
          .to raise_error(Squishling::ConfigurationError, /max_total_output_tokens must be a positive Integer/)
        expect { klass.squish(:call, max_total_input_tokens: bad) }
          .to raise_error(Squishling::ConfigurationError, /max_total_input_tokens must be a positive Integer/)
        expect { Squishling.config.default_max_total_output_tokens = bad }
          .to raise_error(Squishling::ConfigurationError, /default_max_total_output_tokens/)
      end
    end
  end

  describe "with the squishsum harnesses" do
    let(:high) { { "priority" => "high", "team" => "api" } }
    let(:low) { { "priority" => "low", "team" => "api" } }
    let(:sampler) do
      Class.new do
        include Squishling

        squishling escalation: [{ model: "claude-haiku-4-5", attempts: 2 },
                                { model: "claude-sonnet-5-5", attempts: 2 }],
          harness: :squishsum, max_total_output_tokens: 15_000
        purpose "Triage the ticket."
        output_schema do
          string :priority
          string :team
        end
      end
    end

    def tokens(output)
      { input_tokens: 10, output_tokens: output }
    end

    it "doesn't start another round of retries once the samples used the budget" do
      chats = stub_llm_chats([invalid, valid], [invalid, valid])

      expect { sampler.call(text: "x") }.to raise_error(Squishling::BudgetExhaustedError) { |error|
        expect(error.used).to eq(input_tokens: 200, output_tokens: 20_000)
        expect(error.attempts).to eq(1)
        expect(error.models).to eq(["claude-haiku-4-5"])
        expect(error.raw).to eq({ "label" => 1 })
      }
      expect(chats.size).to eq(2)
      expect(chats.map { |chat| chat.messages.size }).to eq([1, 1])
    end

    it "returns the samples' agreed result when the round itself spent the budget" do
      chats = stub_llm_chats([FakeChat::Response.new(high, nil, tokens(9_000))],
        [FakeChat::Response.new(high, nil, tokens(9_000))])

      expect(sampler.call(text: "x").priority).to eq("high")
      expect(chats.size).to eq(2)
    end

    it "returns the judge's pick when the judge's own reply spent the budget" do
      sampler.squishling(harness: :judged_squishsum, max_total_output_tokens: 12_000)
      verdict = FakeChat::Response.new({ "verdict" => "a", "reason" => "more urgent" }, nil, tokens(20_000))
      chats = stub_llm_chats([FakeChat::Response.new(high, nil, tokens(5_000))],
        [FakeChat::Response.new(low, nil, tokens(5_000))], [verdict])

      expect(sampler.call(text: "x").priority).to eq("high")
      expect(chats.size).to eq(3)
    end

    it "raises the budget error instead of calling a judge the samples left no budget for" do
      sampler.squishling(harness: :judged_squishsum)
      chats = stub_llm_chats(
        [FakeChat::Response.new(high, nil, tokens(9_000))], [FakeChat::Response.new(low, nil, tokens(9_000))]
      )

      expect { sampler.call(text: "x") }.to raise_error(Squishling::BudgetExhaustedError) { |error|
        expect(error).not_to be_a(Squishling::DisagreementError)
        expect(error.raw).to be_nil
      }
      expect(chats.size).to eq(2)
    end

    it "doesn't ask a System One judge once the samples used the budget" do
      sampler.squishling(harness: { type: :judged_squishsum, judge: { model: "jev-latest", type: :judgment } })
      stub_llm_chats([FakeChat::Response.new(high, nil, tokens(9_000))],
        [FakeChat::Response.new(low, nil, tokens(9_000))])
      calls = stub_judgment({ choice: :a, probabilities: { a: 0.9, b: 0.05, neither: 0.05 } })

      expect { sampler.call(text: "x") }.to raise_error(Squishling::BudgetExhaustedError)
      expect(calls).to be_empty
    end

    it "counts the judge's tokens, so a spent budget stops the judge's retries" do
      sampler.squishling(harness: :judged_squishsum, max_total_output_tokens: 20_000)
      sample = ->(content) { FakeChat::Response.new(content, nil, tokens(5_000)) }
      bad_verdict = FakeChat::Response.new({ "verdict" => "c", "reason" => "?" }, nil, tokens(15_000))
      chats = stub_llm_chats([sample.call(high)], [sample.call(low)], [bad_verdict])

      expect { sampler.call(text: "x") }.to raise_error(Squishling::BudgetExhaustedError) { |error|
        expect(error.used[:output_tokens]).to eq(25_000)
      }
      expect(chats.size).to eq(3)
    end
  end

  describe "with a custom harness" do
    it "applies to the run's escalate" do
      Squishling.register_harness(:once) do
        def call(run)
          run.escalate
        end
      end
      klass.squishling(harness: :once, max_total_output_tokens: 15_000)
      chats = stub_llm(invalid, invalid, invalid, invalid)

      expect { klass.call(text: "x") }.to raise_error(Squishling::BudgetExhaustedError)
      expect(chats.map { |chat| chat.messages.size }).to eq([2])
    end
  end

  describe Squishling::Budget::Tally do
    it "counts a judgment's tokens, which are given as input and output readers" do
      judgment = Struct.new(:tokens, :model).new(Struct.new(:input, :output).new(40, 60), "jev-latest")
      tally = described_class.new({ output: 100 })

      tally.add(judgment)

      expect(tally.exhausted).to be_nil
      tally.add(judgment)
      expect(tally.exhausted).to eq(limit: :max_total_output_tokens, max: 100,
        used: { input_tokens: 80, output_tokens: 120 })
    end

    it "is exhausted exactly when a total reaches its limit" do
      tally = described_class.new({ output: 100 })

      tally.add(Squishling::Adapter::Response.new(content: "{}", tokens: { output_tokens: 99 }))
      expect(tally.exhausted).to be_nil

      tally.add(Squishling::Adapter::Response.new(content: "{}", tokens: { output_tokens: 1 }))
      expect(tally.exhausted).to include(limit: :max_total_output_tokens, max: 100)
    end

    it "counts nothing for a response without token counts, or with counts that aren't positive Integers" do
      tally = described_class.new({ output: 1 })

      tally.add(Squishling::Adapter::Response.new(content: "{}"))
      tally.add(nil)
      tally.add(Squishling::Adapter::Response.new(content: "{}", tokens: { output_tokens: -5, input_tokens: "7" }))
      tally.add(Squishling::Adapter::Response.new(content: "{}", tokens: { output_tokens: 0.5 }))

      expect(tally.exhausted).to be_nil
    end

    it "is exhausted by whichever limit is reached first" do
      tally = described_class.new({ output: 1_000, input: 50 })

      tally.add(Squishling::Adapter::Response.new(content: "{}", tokens: { input_tokens: 60, output_tokens: 10 }))

      expect(tally.exhausted).to include(limit: :max_total_input_tokens, max: 50)
    end
  end
end
