# frozen_string_literal: true

require "squishling/testing"

# The final squawk report for a call that a token budget or a disagreement ended (metadata[:stopped]): neither has
# an attempt of its own to report, so squawk_on: :final and :rejections would otherwise miss it.
RSpec.describe "Squishling squawk when a call is stopped" do
  include Squishling::Testing::RSpec

  let(:calls) { [] }
  let(:recorder) { ->(**payload) { calls << payload } }
  let(:high) { { "priority" => "high", "team" => "api" } }
  let(:low) { { "priority" => "low", "team" => "api" } }
  let(:klass) do
    Class.new do
      include Squishling

      squishling escalation: [{ model: "claude-haiku-4-5", attempts: 2 }, { model: "claude-sonnet-5-5", attempts: 2 }]
      purpose "Classify."
      output_schema { string :label }
    end
  end
  let(:sampler) do
    Class.new do
      include Squishling

      squishling escalation: [{ model: "claude-haiku-4-5", attempts: 2 }, "claude-sonnet-5-5"], harness: :squishsum
      purpose "Triage the ticket."
      output_schema do
        string :priority
        string :team
      end
    end
  end

  def response(content, output: 10_000)
    FakeChat::Response.new(content, nil, { input_tokens: 100, output_tokens: output })
  end

  def invalid(output: 10_000) = response({ "label" => 1 }, output:)

  # [attempt, attempts, final, stopped, error class] of each report.
  def summary
    calls.map { |call| call[:metadata].values_at(:attempt, :attempts, :final, :stopped) << call[:error].class }
  end

  before { Squishling.configure { |c| c.squawk = recorder } }

  describe "on the token budget" do
    before do
      klass.squishling(max_total_output_tokens: 25_000)
      stub_llm(invalid, invalid, invalid, invalid)
    end

    it "reports the stop after the rejections that led to it, which keep final: false" do
      expect { klass.call(text: "x") }.to raise_error(Squishling::BudgetExhaustedError)

      expect(summary).to eq(
        [[1, 4, false, nil, Squishling::InvalidOutputError], [2, 4, false, nil, Squishling::InvalidOutputError],
         [3, 4, false, nil, Squishling::InvalidOutputError], [3, 3, true, :budget, Squishling::BudgetExhaustedError]]
      )
    end

    it "sends the error, the input, and no output, provider, or params" do
      expect { klass.call(text: "x") }.to raise_error(Squishling::BudgetExhaustedError) { |error|
        stop = calls.last
        expect(stop[:error]).to equal(error)
        expect(stop[:output]).to be_nil
        expect(stop[:metadata]).to include(
          label: "#{klass}#call", repeated: false, role: nil, sample: nil, model: "claude-sonnet-5-5", provider: nil,
          params: nil, usage: nil, finish_reason: nil
        )
        expect(JSON.parse(stop[:metadata][:input])).to eq("arguments" => { "text" => "x" })
      }
    end

    it "is the only report under :final" do
      klass.squishling(squawk_on: :final)

      expect { klass.call(text: "x") }.to raise_error(Squishling::BudgetExhaustedError)
      expect(summary).to eq([[3, 3, true, :budget, Squishling::BudgetExhaustedError]])
    end

    it "reaches :rejections, :retries, and :all too" do
      %i[rejections retries all].each do |mode|
        calls.clear
        klass.squishling(squawk_on: mode)
        stub_llm(invalid, invalid, invalid, invalid)

        expect { klass.call(text: "x") }.to raise_error(Squishling::BudgetExhaustedError)
        expect(summary.last).to eq([3, 3, true, :budget, Squishling::BudgetExhaustedError])
      end
    end

    it "is reported once, before squish_fallback takes over" do
      order = []
      klass.squishling(squawk: ->(metadata:, **) { order << [:squawk, metadata[:stopped]] }, squawk_on: :final)
      klass.squish_fallback do |error, **|
        order << [:fallback, error.class]
        { label: "fallback" }
      end

      expect(klass.call(text: "x").label).to eq("fallback")
      expect(order).to eq([%i[squawk budget], [:fallback, Squishling::BudgetExhaustedError]])
    end

    it "reports nothing for squawk: false" do
      klass.squishling(squawk: false)

      expect { klass.call(text: "x") }.to raise_error(Squishling::BudgetExhaustedError)
      expect(calls).to be_empty
    end
  end

  describe "on the token budget with no rejection before it" do
    it "reports the stop once a judge has no budget left, though the samples were accepted" do
      sampler.squishling(harness: :judged_squishsum, max_total_output_tokens: 15_000, squawk_on: :final)
      stub_llm_chats([response(high)], [response(low)])

      expect { sampler.call(text: "x") }.to raise_error(Squishling::BudgetExhaustedError) { |error|
        expect(error.raw).to be_nil
      }
      expect(summary).to eq([[0, 0, true, :budget, Squishling::BudgetExhaustedError]])
    end

    it "reports the stop of a sample that ran out of budget before its retry" do
      sampler.squishling(max_total_output_tokens: 15_000, squawk_on: :final)
      stub_llm_chats([invalid, response(high)], [invalid, response(high)])

      expect { sampler.call(text: "x") }.to raise_error(Squishling::BudgetExhaustedError)
      expect(summary.last).to eq([1, 1, true, :budget, Squishling::BudgetExhaustedError])
    end

    it "reports the stop of a judge that ran out of budget before its retry" do
      sampler.squishling(escalation: ["claude-haiku-4-5", { model: "claude-sonnet-5-5", attempts: 2 }],
        harness: :judged_squishsum, max_total_output_tokens: 20_000, squawk_on: :final)
      bad_verdict = response({ "verdict" => "c", "reason" => "?" }, output: 15_000)
      stub_llm_chats([response(high, output: 5_000)], [response(low, output: 5_000)], [bad_verdict])

      expect { sampler.call(text: "x") }.to raise_error(Squishling::BudgetExhaustedError)
      expect(summary.last).to eq([1, 1, true, :budget, Squishling::BudgetExhaustedError])
    end
  end

  describe "on a disagreement" do
    it "reports the squishsum samples' disagreement, which no attempt reported" do
      sampler.squishling(squawk_on: :rejections)
      stub_llm_chats([high], [low])

      expect { sampler.call(text: "x") }.to raise_error(Squishling::DisagreementError) { |error|
        expect(summary).to eq([[0, 0, true, :disagreement, Squishling::DisagreementError]])
        expect(calls.first).to include(output: nil, error: equal(error))
        expect(calls.first[:metadata]).to include(model: "claude-haiku-4-5", role: nil, sample: nil)
      }
    end

    it "is the only report under :final, since the accepted samples were not final" do
      sampler.squishling(squawk_on: :final)
      stub_llm_chats([high], [low])

      expect { sampler.call(text: "x") }.to raise_error(Squishling::DisagreementError)
      expect(summary).to eq([[0, 0, true, :disagreement, Squishling::DisagreementError]])
    end

    it "follows the samples' own reports under :all" do
      stub_llm_chats([high], [low])
      sampler.squishling(squawk_on: :all)

      expect { sampler.call(text: "x") }.to raise_error(Squishling::DisagreementError)
      expect(summary.map { |row| row[3] }).to eq([nil, nil, :disagreement])
    end

    it "reports a judge that rejected both candidates, with the judge's model last" do
      sampler.squishling(harness: :judged_squishsum, squawk_on: :final)
      stub_llm_chats([high], [low], [{ "verdict" => "neither", "reason" => "both misread the ticket" }])

      expect { sampler.call(text: "x") }.to raise_error(Squishling::DisagreementError)
      stop = calls.find { |call| call[:metadata][:stopped] }
      expect(stop[:metadata][:model]).to eq("claude-sonnet-5-5")
      expect(calls.count { |call| call[:metadata][:stopped] }).to eq(1)
    end

    it "reports a DisagreementError a custom harness raises, once" do
      Squishling.register_harness(:never_agree) do
        def call(run)
          stage = run.stages.first
          raise Squishling::DisagreementError.new(candidates: run.samples([stage, stage]), models: [stage.first.model])
        end
      end
      sampler.squishling(harness: :never_agree, squawk_on: :final)
      stub_llm_chats([high], [low])

      expect { sampler.call(text: "x") }.to raise_error(Squishling::DisagreementError)
      expect(summary).to eq([[0, 0, true, :disagreement, Squishling::DisagreementError]])
    end

    it "is reported before squish_fallback takes over" do
      order = []
      sampler.squishling(squawk: ->(metadata:, **) { order << [:squawk, metadata[:stopped]] }, squawk_on: :final)
      sampler.squish_fallback do |error, **|
        order << :fallback
        error.candidates.last
      end
      stub_llm_chats([high], [low])

      expect(sampler.call(text: "x").priority).to eq("low")
      expect(order).to eq([%i[squawk disagreement], :fallback])
    end
  end

  describe "what is not a stop" do
    it "adds no report when a call ends on its last invalid attempt, which already carried final: true" do
      stub_llm(invalid, invalid, invalid, invalid)

      expect { klass.call(text: "x") }.to raise_error(Squishling::InvalidOutputError)
      expect(summary.map { |row| row[3] }).to all(be_nil)
      expect(summary.last).to eq([4, 4, true, nil, Squishling::InvalidOutputError])
    end

    it "adds no stop report for an accepted call" do
      stub_llm({ "label" => "ok" })
      klass.call(text: "x")

      expect(summary).to eq([[1, 4, false, nil, NilClass]])
    end

    it "reports nothing when no hook is set" do
      Squishling.configure { |c| c.squawk = nil }
      sampler.squishling(squawk: nil)
      stub_llm_chats([high], [low])

      expect { sampler.call(text: "x") }.to raise_error(Squishling::DisagreementError)
      expect(calls).to be_empty
    end
  end

  describe "with the test helpers" do
    it "is recorded by capture_squawk" do
      fake_squishling do |llm|
        llm.sample("a").reply(high)
        llm.sample("b").reply(low)
      end
      capture = capture_squawk

      with_squawk(capture) do
        expect { sampler.call(text: "x") }.to raise_error(Squishling::DisagreementError)
      end

      stop = capture.calls.last
      expect(stop.metadata).to include(stopped: :disagreement, final: true)
      expect(stop.error).to be_a(Squishling::DisagreementError)
      expect(stop.output).to be_nil
    end

    it "is not produced by stub_error, which replaces the method without running Squishling" do
      Squishling::Testing.stub_error(sampler, :disagreement, candidates: [high, low]) do
        expect { sampler.call(text: "x") }.to raise_error(Squishling::DisagreementError)
      end

      expect(calls).to be_empty
    end
  end
end
