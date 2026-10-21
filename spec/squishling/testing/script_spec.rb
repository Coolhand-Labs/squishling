# frozen_string_literal: true

require "squishling/testing"

RSpec.describe Squishling::Testing::Script do
  include Squishling::Testing::RSpec

  let(:klass) do
    Class.new do
      include Squishling

      squishling escalation: ["flash", "pro"], harness: :squishsum
      purpose "Triage the ticket."
      output_schema do
        string :priority
        string :team
      end

      def self.to_s = "Triager"
    end
  end

  let(:high) { { "priority" => "high", "team" => "api" } }
  let(:low) { { "priority" => "low", "team" => "api" } }

  describe ":squishsum" do
    it "gives each sample its own script, whatever order the sample threads run in" do
      fake = fake_squishling do |llm|
        llm.sample("a").reply(high)
        llm.sample("b").reply(high)
      end

      50.times { expect(klass.call(text: "x").priority).to eq("high") }
      expect(fake.requests_for(sample: "a").size).to eq(50)
      expect(fake.requests_for(sample: "b").size).to eq(50)
      expect(fake.requests.map(&:role).uniq).to eq([:sample])
    end

    it "raises a DisagreementError carrying both candidates when the samples differ" do
      fake_squishling do |llm|
        llm.sample("a").reply(high)
        llm.sample("b").reply(low)
      end

      expect { klass.call(text: "x") }.to raise_error(Squishling::DisagreementError) { |error|
        expect(error.candidates.map(&:priority)).to eq(%w[high low])
        expect(error.verdict).to be_nil
      }
    end

    it "keeps a sample's retry in its own conversation" do
      klass.squishling escalation: [{ model: "flash", attempts: 2 }, "pro"]
      fake = fake_squishling do |llm|
        llm.sample("a").reply({ "priority" => "high" }, high)
        llm.sample("b").reply(high)
      end
      klass.call(text: "x")

      by_sample = fake.requests.group_by(&:sample)
      expect(by_sample["a"].map(&:conversation).uniq.size).to eq(1)
      expect(by_sample["a"].last.errors).to include(a_string_matching(/team/))
      expect(by_sample["b"].first.conversation).not_to eq(by_sample["a"].first.conversation)
    end

    it "lets a step script cover samples that no sample script claims" do
      fake_squishling { |llm| llm.step(:any).reply(high) }

      expect(klass.call(text: "x").priority).to eq("high")
    end
  end

  describe ":judged_squishsum with a chat judge" do
    before { klass.squishling(harness: { type: :judged_squishsum, judge: "opus" }) }

    it "picks the candidate the scripted verdict names" do
      fake = fake_squishling do |llm|
        llm.sample("a").reply(high)
        llm.sample("b").reply(low)
        llm.judge.verdict(:b, reason: "b fits")
      end

      expect(klass.call(text: "x").priority).to eq("low")
      judge = fake.requests_for(role: :judge).first
      expect(judge).to have_attributes(model: "opus", type: :chat)
      expect(judge.candidates).to eq({ "a" => high, "b" => low })
      expect(judge.arguments).to eq({ "text" => "x" })
    end

    it "rejects both candidates when the verdict is neither" do
      fake_squishling do |llm|
        llm.sample("a").reply(high)
        llm.sample("b").reply(low)
        llm.judge.verdict(:neither)
      end

      expect { klass.call(text: "x") }
        .to raise_error(Squishling::DisagreementError) { |error| expect(error.verdict).to eq(:neither) }
    end

    it "can answer the judge off-schema, so it is re-asked" do
      klass.squishling(harness: { type: :judged_squishsum, judge: { model: "opus", attempts: 2 } })
      fake = fake_squishling do |llm|
        llm.sample("a").reply(high)
        llm.sample("b").reply(low)
        llm.judge.reply({ "verdict" => "maybe", "reason" => "" }).verdict(:a)
      end

      expect(klass.call(text: "x").priority).to eq("high")
      expect(fake.requests_for(role: :judge).size).to eq(2)
    end

    it "raises a failure for the judge's chat request, and can run out of verdicts with once" do
      klass.squishling(harness: { type: :judged_squishsum, judge: { model: "opus", attempts: 2 } })
      fake_squishling do |llm|
        llm.sample("a").reply(high)
        llm.sample("b").reply(low)
        llm.judge.fail(:server_error).verdict(:b).once
      end

      expect(klass.call(text: "x").priority).to eq("low")
      expect { klass.call(text: "x") }.to raise_error(Squishling::Testing::UnscriptedRequestError, /no answers left/)
    end

    it "rejects a verdict that is not a choice" do
      expect { fake_squishling { |llm| llm.judge.verdict(:c) } }.to raise_error(ArgumentError, /judge choice/)
    end
  end

  describe ":judged_squishsum with a System One judgment" do
    let(:jev) { { model: "jev-latest", type: :judgment, min_confidence: 0.8 } }

    before { klass.squishling(harness: { type: :judged_squishsum, judge: jev }) }

    it "accepts a pick at or above min_confidence" do
      fake = fake_squishling do |llm|
        llm.sample("a").reply(high)
        llm.sample("b").reply(low)
        llm.judge.judgment(:b, confidence: 0.9)
      end

      expect(klass.call(text: "x").priority).to eq("low")
      judgment = fake.requests_for(role: :judge).first
      expect(judgment).to have_attributes(type: :judgment, model: "jev-latest")
      expect(judgment.candidates).to eq({ "a" => high, "b" => low })
    end

    it "rejects a pick below min_confidence" do
      fake_squishling do |llm|
        llm.sample("a").reply(high)
        llm.sample("b").reply(low)
        llm.judge.judgment(:a, confidence: 0.5)
      end

      expect { klass.call(text: "x") }
        .to raise_error(Squishling::DisagreementError, /below min_confidence/)
    end

    it "fails a judgment by intent, and moves on to the judge's next attempt" do
      klass.squishling(harness: { type: :judged_squishsum, judge: jev.merge(attempts: 2) })
      fake_squishling do |llm|
        llm.sample("a").reply(high)
        llm.sample("b").reply(low)
        llm.judge.fail_judgment(:rate_limit).judgment(:a)
      end

      expect(klass.call(text: "x").priority).to eq("high")
    end
  end

  describe "judgments when provider calls are forbidden" do
    it "refuses a System One judgment at the judge, after the samples were scripted" do
      klass.squishling(harness: { type: :judged_squishsum, judge: { model: "jev", type: :judgment } })
      fake_squishling do |llm|
        llm.sample("a").reply(high)
        llm.sample("b").reply(low)
      end
      adapter = Squishling.config.adapter
      Squishling::Testing.forbid_provider_calls!

      expect { klass.call(text: "x") }.to raise_error(Squishling::Testing::ProviderCallError)
      expect(adapter.requests).to be_empty
    end

    it "rejects a confidence that isn't a probability" do
      expect { fake_squishling { |llm| llm.judge.judgment(:a, confidence: 1.5) } }
        .to raise_error(ArgumentError, /probability/)
    end
  end
end
