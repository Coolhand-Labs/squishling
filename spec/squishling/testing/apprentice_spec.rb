# frozen_string_literal: true

require "squishling/testing"

RSpec.describe "Squishling::Testing with apprentice mode" do
  include Squishling::Testing::RSpec

  let(:stats) { [] }
  let(:klass) do
    log = stats
    Class.new do
      include Squishling

      squishling model: "test-model", apprentice_mode: { report: ->(match:, **) { log << match } }
      purpose "Triage the ticket."
      output_schema do
        string :priority
      end

      def self.to_s = "Triage"

      def call(text:)
        { priority: text.include?("down") ? "high" : "low" }
      end
    end
  end

  # The one item of a list that should hold exactly one.
  def sole(list)
    expect(list.size).to eq(1)
    list.first
  end

  describe "disable_apprentice!" do
    it "lets a class's tests ignore its shadow runs, with provider calls forbidden" do
      forbid_provider_calls!
      disable_apprentice!

      expect(klass.call(text: "site down").priority).to eq("high")
      expect(stats).to be_empty
    end

    it "is put back by Testing.reset!" do
      disable_apprentice!
      Squishling::Testing.reset!

      expect(Squishling.config.apprentice_enabled).to be(true)
    end
  end

  describe "without_apprentice" do
    it "turns shadow runs off for the block only" do
      forbid_provider_calls!

      without_apprentice { expect(klass.call(text: "site down").priority).to eq("high") }

      expect(Squishling.config.apprentice_enabled).to be(true)
      expect { klass.call(text: "site down") }.to raise_error(Squishling::Testing::ProviderCallError)
    end
  end

  describe "with_apprentice" do
    it "records each shadow run's report, after the class's own report hook" do
      fake_squishling { |script| script.apprentice.reply(priority: "low") }

      capture = with_apprentice { klass.call(text: "site down") }

      report = sole(capture.reports)
      expect(report).to have_attributes(match: false, error: nil, inputs: { text: "site down" })
      expect(report.ruby.priority).to eq("high")
      expect(report.llm.priority).to eq("low")
      expect(report.metadata).to include(label: "Triage#call")
      expect(stats).to eq([false])
    end

    it "turns apprentice mode back on after disable_apprentice!, and off again afterwards" do
      fake_squishling { |script| script.apprentice.reply(priority: "high") }
      disable_apprentice!

      capture = with_apprentice { klass.call(text: "site down") }

      expect(sole(capture.reports).match).to be(true)
      expect(Squishling.config.apprentice_enabled).to be(false)
      expect(Squishling.config.apprentice_listener).to be_nil
    end

    it "records a shadow run that failed" do
      fake_squishling { |script| script.apprentice.fail(:rate_limit) }

      capture = with_apprentice { klass.call(text: "site down") }

      expect(sole(capture.reports)).to have_attributes(llm: nil, match: nil, error: an_instance_of(Squishling::LLMError))
    end

    it "fails rather than return a capture missing the runs still pending" do
      runner = Object.new.tap do |object|
        object.define_singleton_method(:call) { |_job| nil }
        object.define_singleton_method(:drain) { |timeout:| timeout.nil? }
      end
      Squishling.configure { |c| c.apprentice_runner = runner }
      fake_squishling

      expect { with_apprentice { klass.call(text: "site down") } }
        .to raise_error(Squishling::Testing::SetupError, /still pending after 5 seconds/)
      expect(Squishling.config.apprentice_listener).to be_nil
    ensure
      Squishling.configure { |c| c.apprentice_runner = :inline } # so the mixin's reset! has nothing left to wait for
    end

    it "records the reports of a class that declares no report hook" do
      klass.squishling(apprentice_mode: { report: false })
      fake_squishling { |script| script.apprentice.reply(priority: "high") }

      capture = with_apprentice { klass.call(text: "site down") }

      expect(sole(capture.reports).match).to be(true)
      expect(stats).to be_empty
    end

    it "waits for a background runner's shadow runs before returning" do
      Squishling.configure { |c| c.apprentice_runner = :thread }
      fake_squishling { |script| script.apprentice.reply(priority: "high") }

      capture = with_apprentice { klass.call(text: "site down") }

      expect(sole(capture.reports).match).to be(true)
    end
  end

  describe "script.apprentice" do
    it "answers the shadow run, while step answers the calls routed to the LLM" do
      klass.squish_when { |text:| text.end_with?("?") }
      adapter = fake_squishling do |script|
        script.step.reply(priority: "medium")
        script.apprentice.reply(priority: "high")
      end

      expect(klass.call(text: "is it down?").priority).to eq("medium")
      capture = with_apprentice { klass.call(text: "site down") }

      expect(sole(capture.reports).match).to be(true)
      expect(adapter.requests_for(apprentice: true).map { |request| request.arguments["text"] }).to eq(["site down"])
      expect(adapter.requests_for(apprentice: false).map { |request| request.arguments["text"] }).to eq(["is it down?"])
    end

    it "narrows by attempt like step" do
      klass.squishling(escalation: [{ model: "test-model", attempts: 2 }])
      fake_squishling do |script|
        script.apprentice(attempt: 1).reply(priority: 1)
        script.apprentice(attempt: 2).reply(priority: "high")
      end

      capture = with_apprentice { klass.call(text: "site down") }

      expect(sole(capture.reports).match).to be(true)
    end

    it "leaves a shadow run's samples to the sample rules" do
      klass.squishling(harness: :squishsum, escalation: %w[model-a model-b])
      fake_squishling do |script|
        script.apprentice.reply(priority: "wrong")
        script.sample(:a).reply(priority: "high")
        script.sample(:b).reply(priority: "high")
      end

      capture = with_apprentice { klass.call(text: "site down") }

      expect(sole(capture.reports).match).to be(true)
    end

    it "names the shadow run in an unscripted judgment's error, and marks the recorded judgment" do
      klass.squishling(harness: { type: :judged_squishsum, judge: { model: "judge-model", type: :judgment } },
        escalation: %w[model-a model-b])
      adapter = fake_squishling do |script|
        script.sample(:a).reply(priority: "high")
        script.sample(:b).reply(priority: "low")
      end

      expect { klass.call(text: "site down") }
        .to raise_error(Squishling::Testing::UnscriptedRequestError, /unscripted judgment .*apprentice: true/)
      expect(adapter.requests_for(role: :judge).map(&:apprentice?)).to eq([true])
    end

    it "doesn't answer requests outside a shadow run" do
      klass.squish_when { |**| true }
      fake_squishling { |script| script.apprentice.reply(priority: "high") }

      expect { klass.call(text: "x") }.to raise_error(Squishling::Testing::UnscriptedRequestError, /apprentice: true/)
    end
  end

  it "rejects a non-boolean apprentice_enabled at setup" do
    expect { Squishling.configure { |c| c.apprentice_enabled = nil } }
      .to raise_error(Squishling::ConfigurationError, /apprentice_enabled must be true or false/)
  end

  it "stops every shadow run with config.apprentice_enabled = false" do
    Squishling.configure { |c| c.apprentice_enabled = false }
    forbid_provider_calls!

    expect(klass.call(text: "site down").priority).to eq("high")
    expect(stats).to be_empty
  end
end
