# frozen_string_literal: true

require "logger"
require "squishling/testing"

RSpec.describe "Squishling apprentice mode" do
  let(:reports) { [] }
  let(:recorder) { ->(**report) { reports << report } }
  let(:klass) do
    hook = recorder
    Class.new do
      include Squishling

      squishling model: "test-model", apprentice_mode: { report: hook }
      purpose "Classify the ticket."
      output_schema do
        string :priority
      end

      def self.to_s = "Triage"

      def call(text:)
        { priority: text.include?("down") ? "high" : "low" }
      end
    end
  end

  let(:high) { { "priority" => "high" } }
  let(:low) { { "priority" => "low" } }

  # The one item of a list that should hold exactly one.
  def sole(list)
    expect(list.size).to eq(1)
    list.first
  end

  describe "a call" do
    it "returns the Ruby result and reports the LLM's alongside it, matched" do
      chats = stub_llm(high)

      result = klass.call(text: "site down")

      expect(result.priority).to eq("high")
      expect(result.squished?).to be(false)
      expect(chats.size).to eq(1)
      report = sole(reports)
      expect(report[:ruby]).to equal(result)
      expect(report[:llm].priority).to eq("high")
      expect(report[:llm].squished?).to be(true)
      expect(report).to include(match: true, error: nil, inputs: { text: "site down" })
      metadata = report[:metadata]
      expect(metadata).to include(label: "Triage#call", request_id: "#{metadata[:call_id]}.1")
      expect(metadata[:call_id]).to match(/\A\h{8}-/)
      expect(metadata[:ruby_seconds]).to be_a(Float)
      expect(metadata[:llm_seconds]).to be_a(Float)
    end

    it "reports a mismatch, and still returns the Ruby result" do
      stub_llm(low)

      expect(klass.call(text: "site down").priority).to eq("high")
      expect(sole(reports)).to include(match: false, error: nil)
      expect(sole(reports)[:llm].priority).to eq("low")
    end

    it "compares with compare:, evaluated against the instance with both results and the inputs" do
      klass.class_eval { def strict? = false }
      klass.squishling(apprentice_mode: {
        report: recorder,
        compare: ->(ruby, llm, text:) { strict? ? ruby == llm : [ruby.priority, llm.priority, text].size == 3 }
      })
      stub_llm(low)

      klass.call(text: "site down")

      expect(sole(reports)[:match]).to be(true)
    end

    it "runs only on the calls when: picks, evaluated against the instance with the inputs" do
      klass.squishling(apprentice_mode: { report: recorder, when: ->(text:) { text.start_with?("shadow") && ready? } })
      klass.class_eval { def ready? = true }
      chats = stub_llm(high)

      klass.call(text: "site down")
      klass.call(text: "shadow: site down")

      expect(chats.size).to eq(1)
      expect(reports.map { |report| report[:inputs] }).to eq([{ text: "shadow: site down" }])
    end

    it "gets the reports the hook names, and only those" do
      seen = []
      klass.squishling(apprentice_mode: { report: ->(match:, metadata:) { seen << [match, metadata[:label]] } })
      stub_llm(high)

      klass.call(text: "site down")

      expect(seen).to eq([[true, "Triage#call"]])
    end

    it "marks the shadow run's attempts in squawk" do
      squawked = []
      Squishling.configure { |c| c.squawk = ->(metadata:, **) { squawked << metadata } }
      stub_llm(high)

      klass.call(text: "site down")

      expect(sole(squawked)).to include(apprentice: true, call_id: sole(reports)[:metadata][:call_id])
    end

    it "doesn't run the LLM when squish_when already sent the call there" do
      klass.squish_when { |text:| text.include?("?") }
      chats = stub_llm(high)

      expect(klass.call(text: "?").priority).to eq("high")
      expect(chats.size).to eq(1)
      expect(reports).to be_empty
    end

    it "doesn't run the LLM after squish! handed the call over" do
      klass.define_method(:call) { |**| squish! }
      chats = stub_llm(high)

      expect(klass.call(text: "x").squished?).to be(true)
      expect(chats.size).to eq(1)
      expect(reports).to be_empty
    end

    it "doesn't run the LLM when the Ruby implementation raises" do
      klass.define_method(:call) { |text:| raise ArgumentError, "bad #{text}" }
      chats = stub_llm(high)

      expect { klass.call(text: "x") }.to raise_error(ArgumentError, "bad x")
      expect(chats).to be_empty
      expect(reports).to be_empty
    end

    it "shadows a recursive method once, for the outermost call" do
      counter = squishling_class do
        squishling model: "test-model", purpose: "Count down."
        output_schema { integer :n }
        def call(n:) = n.zero? ? { n: 0 } : { n: call(n: n - 1).n + 1 }
      end
      counter.squishling(apprentice_mode: { report: recorder })
      chats = stub_llm({ "n" => 3 })

      expect(counter.call(n: 3).n).to eq(3)
      expect(chats.size).to eq(1)
      expect(sole(reports)).to include(match: true, inputs: { n: 3 })
    end

    it "doesn't shadow the calls the method makes to itself from the LLM path" do
      klass.purpose { "Classify. Example: #{call(text: 'down').priority}" }
      chats = stub_llm(high)

      klass.call(text: "site down")

      expect(chats.size).to eq(1)
      expect(reports.size).to eq(1)
    end

    it "builds the request before the caller moves on, so later changes to the instance aren't sent" do
      jobs = []
      Squishling.configure { |c| c.apprentice_runner = ->(job) { jobs << job } }
      klass.squish_context :account
      klass.attr_accessor :account
      triage = klass.new.tap { |instance| instance.account = "acme" }
      stub_llm(high)

      triage.call(text: "site down")
      triage.account = "changed"
      expect(reports).to be_empty
      jobs.each(&:call)

      expect(JSON.parse(sole(fake_adapter.chats).transcript.first[:content])["context"]).to eq("account" => "acme")
      expect(sole(reports)[:match]).to be(true)
    end
  end

  describe "a shadow run that fails" do
    it "reports an invalid output and doesn't use squish_fallback" do
      fallbacks = []
      klass.squish_fallback { |error, **| (fallbacks << error) && { priority: "fallback" } }
      stub_llm({ "priority" => 1 })

      expect(klass.call(text: "site down").priority).to eq("high")
      expect(sole(reports)).to include(llm: nil, match: nil)
      expect(sole(reports)[:error]).to be_a(Squishling::InvalidOutputError)
      expect(sole(reports)[:metadata]).to include(request_id: nil, call_id: a_string_matching(/\A\h{8}-/))
      expect(fallbacks).to be_empty
    end

    it "reports a provider failure" do
      stub_llm(Squishling::LLMError.new("rate limited"))

      expect(klass.call(text: "site down").priority).to eq("high")
      expect(sole(reports)[:error]).to be_a(Squishling::LLMError)
    end

    it "reports a setup mistake rather than raising it" do
      klass.purpose ""
      chats = stub_llm(high)

      expect(klass.call(text: "site down").priority).to eq("high")
      expect(sole(reports)[:error]).to be_a(Squishling::ConfigurationError)
      expect(sole(reports)[:metadata]).to include(call_id: nil, request_id: nil, llm_seconds: nil)
      expect(chats).to be_empty
    end

    it "reports an exception from when:" do
      klass.squishling(apprentice_mode: { report: recorder, when: ->(**) { raise KeyError, "no sampler" } })

      expect(klass.call(text: "site down").priority).to eq("high")
      expect(sole(reports)[:error]).to be_a(KeyError)
    end

    it "reports a NotImplementedError from compare:, which isn't a StandardError" do
      klass.squishling(apprentice_mode: { report: recorder, compare: ->(*, **) { raise NotImplementedError, "todo" } })
      stub_llm(high)

      expect(klass.call(text: "site down").priority).to eq("high")
      expect(sole(reports)[:error]).to be_a(NotImplementedError)
    end

    it "reports an exception from compare:, with the LLM's result" do
      klass.squishling(apprentice_mode: { report: recorder, compare: ->(*, **) { raise ZeroDivisionError } })
      stub_llm(high)

      expect(klass.call(text: "site down").priority).to eq("high")
      expect(sole(reports)).to include(match: nil)
      expect(sole(reports)[:llm].priority).to eq("high")
      expect(sole(reports)[:error]).to be_a(ZeroDivisionError)
    end

    it "logs the failure without the model's output" do
      io = StringIO.new
      Squishling.configure { |c| c.logger = Logger.new(io) }
      stub_llm({ "priority" => "SECRET_OUTPUT_1" })
      klass.squishling(output_schema: { type: "object", properties: { priority: { enum: %w[high low] } },
                                        required: ["priority"], additionalProperties: false })

      klass.call(text: "site down")

      expect(io.string).to include("Triage#call apprentice LLM run failed: Squishling::InvalidOutputError")
      expect(io.string).not_to include("SECRET_OUTPUT_1")
    end

    it "logs only the class of an exception from the developer's code, whose message may quote the model's output" do
      io = StringIO.new
      Squishling.configure { |c| c.logger = Logger.new(io) }
      klass.squishling(apprentice_mode: {
        report: recorder, compare: ->(_ruby, llm, **) { Integer(llm.priority) }
      })
      stub_llm({ "priority" => "SECRET_OUTPUT_3" })

      expect(klass.call(text: "site down").priority).to eq("high")
      expect(io.string).to include("Triage#call apprentice LLM run failed: ArgumentError")
      expect(io.string).not_to include("SECRET_OUTPUT_3")
      expect(sole(reports)[:error].message).to include("SECRET_OUTPUT_3")
    end

    it "names an anonymous exception class in the log" do
      io = StringIO.new
      Squishling.configure { |c| c.logger = Logger.new(io) }
      anonymous = Class.new(StandardError)
      klass.squishling(apprentice_mode: { report: recorder, when: ->(**) { raise anonymous } })

      klass.call(text: "site down")

      expect(io.string).to include("apprentice LLM run failed: #<Class:0x")
    end

    it "lets the report hook's own exception reach the caller on the inline runner" do
      klass.squishling(apprentice_mode: { report: ->(**) { raise IOError, "stats down" } })
      stub_llm(high)

      expect { klass.call(text: "site down") }.to raise_error(IOError, "stats down")
    end

    it "marks the shadow run's requests in Squishling::Testing" do
      adapter = Squishling::Testing.install { |script| script.step.reply(priority: "low") }

      expect(klass.call(text: "site down").priority).to eq("high")
      expect(adapter.requests.map(&:apprentice?)).to eq([true])
      expect(sole(reports)[:match]).to be(false)
    ensure
      Squishling::Testing.reset!
    end

    it "keeps a held error for a later drain while runs are still pending" do
      error = Squishling::Testing::UnscriptedRequestError.new("unscripted")
      pending = true
      runner = Object.new.tap do |object|
        object.define_singleton_method(:call) { |_job| nil }
        object.define_singleton_method(:drain) { |**| !pending }
      end
      Squishling.configure { |c| c.apprentice_runner = runner }
      Squishling::Apprentice.hold(error)

      expect(Squishling::Apprentice.drain(timeout: 0)).to be(false)
      pending = false
      expect { Squishling::Apprentice.drain }.to raise_error(error)
    end

    it "holds a test's setup mistake from a background run for drain, and Testing.reset! raises it" do
      jobs = []
      Squishling.configure { |c| c.apprentice_runner = ->(job) { jobs << job } }
      Squishling::Testing.install

      expect(klass.call(text: "site down").priority).to eq("high")
      sole(jobs).call

      expect(reports).to be_empty
      expect { Squishling::Testing.reset! }.to raise_error(Squishling::Testing::UnscriptedRequestError)
      expect(Squishling::Apprentice.drain).to be(true)
    end

    it "lets a test's setup mistake through (an unscripted request)" do
      Squishling::Testing.install

      expect { klass.call(text: "site down") }.to raise_error(Squishling::Testing::UnscriptedRequestError)
    ensure
      Squishling::Testing.reset!
    end
  end

  describe "declaring" do
    it "turns off for a method with false, and merges a method's settings over the class's" do
      klass.squish :quiet, apprentice_mode: false do
        string :priority
      end
      klass.squish :sampled, apprentice_mode: { when: ->(**) { false } } do
        string :priority
      end
      klass.define_method(:quiet) { { priority: "low" } }
      klass.define_method(:sampled) { { priority: "low" } }

      expect(klass.squishling_definition(:quiet).apprentice).to be_nil
      expect(klass.squishling_definition(:sampled).apprentice.keys).to contain_exactly(:report, :when)
      expect(klass.squishling_definition(:call).apprentice.keys).to eq([:report])
    end

    it "turns on for one method of a class without it" do
      plain = squishling_class do
        squishling model: "test-model", purpose: "Classify."
        squish :call, apprentice_mode: true do
          string :priority
        end
        def call = { priority: "low" }
      end
      Squishling.configure { |c| c.apprentice_report = ->(**report) { reports << report } }
      stub_llm(low)

      plain.call

      expect(sole(reports)[:match]).to be(true)
    end

    it "inherits the configured report for report: nil" do
      Squishling.configure { |c| c.apprentice_report = ->(**report) { reports << report } }
      klass.squishling(apprentice_mode: { report: nil, when: nil })
      stub_llm(high)

      klass.call(text: "site down")

      expect(sole(reports)[:match]).to be(true)
    end

    it "uses the configured report, which a class's report: false silences" do
      Squishling.configure { |c| c.apprentice_report = ->(**report) { reports << report } }
      klass.squishling(apprentice_mode: true)
      stub_llm(high, high)

      klass.call(text: "site down")
      klass.squishling(apprentice_mode: { report: false })
      klass.call(text: "site down")

      expect(reports.size).to eq(1)
      expect(fake_adapter.chats.size).to eq(2)
    end

    it "is inherited, and a subclass's false turns it off" do
      child = Class.new(klass) { squishling apprentice_mode: false }
      stub_llm(high)

      expect(Class.new(klass).squishling_definition(:call).apprentice).not_to be_nil
      expect(child.squishling_definition(:call).apprentice).to be_nil
    end

    it "rejects a mistake at setup" do
      expect { klass.squishling(apprentice_mode: { sample: 0.1 }) }
        .to raise_error(Squishling::ConfigurationError, /apprentice_mode: unknown key\(s\) :sample/)
      expect { klass.squishling(apprentice_mode: { when: 0.1 }) }
        .to raise_error(Squishling::ConfigurationError, /apprentice_mode when: must be a Proc/)
      expect { klass.squishling(apprentice_mode: { report: ->(output) {} }) }
        .to raise_error(Squishling::ConfigurationError, /report is called with keywords \(ruby:, llm:/)
      expect { klass.squishling(apprentice_mode: { report: ->(verdict:) {} }) }
        .to raise_error(Squishling::ConfigurationError, /report requires unknown keyword\(s\) verdict/)
      expect { klass.squishling(apprentice_mode: "yes") }
        .to raise_error(Squishling::ConfigurationError, /apprentice_mode must be true, false, or a Hash/)
      expect { klass.squish(:other, apprentice_mode: :on) }
        .to raise_error(Squishling::ConfigurationError, /squish apprentice_mode must be/)
      expect { Squishling.configure { |c| c.apprentice_report = Object.new } }
        .to raise_error(Squishling::ConfigurationError, /apprentice_report must respond to call/)
      expect { Squishling.configure { |c| c.apprentice_runner = :sidekiq } }
        .to raise_error(Squishling::ConfigurationError, /apprentice_runner must be :inline or :thread/)
    end
  end

  describe "the runner" do
    it "hands a callable runner the job, which runs the shadow when it is called" do
      jobs = []
      Squishling.configure { |c| c.apprentice_runner = ->(job) { jobs << job } }
      chats = stub_llm(high)

      expect(klass.call(text: "site down").priority).to eq("high")
      expect(chats).to be_empty
      sole(jobs).call

      expect(chats.size).to eq(1)
      expect(sole(reports)[:match]).to be(true)
    end

    it "logs the report hook's exception on a background runner, as there is no caller to raise to" do
      io = StringIO.new
      jobs = []
      Squishling.configure do |c|
        c.logger = Logger.new(io)
        c.apprentice_runner = ->(job) { jobs << job }
      end
      klass.squishling(apprentice_mode: { report: ->(**) { raise IOError, "stats down" } })
      stub_llm(high)

      klass.call(text: "site down")
      expect { sole(jobs).call }.not_to raise_error

      expect(io.string).to include("Triage#call apprentice report failed: IOError")
      expect(io.string).not_to include("stats down")
    end

    it "runs off the caller's thread with :thread, and drains" do
      threads = []
      klass.squishling(apprentice_mode: { report: ->(**) { threads << Thread.current } })
      Squishling.configure { |c| c.apprentice_runner = :thread }
      stub_llm(high)

      expect(klass.call(text: "site down").priority).to eq("high")
      expect(Squishling::Apprentice.drain(timeout: 5)).to be(true)

      expect(sole(threads)).not_to equal(Thread.current)
    end

    it "keeps a failure before the request, and its report, off the caller's thread" do
      jobs = []
      Squishling.configure { |c| c.apprentice_runner = ->(job) { jobs << job } }
      klass.squishling(apprentice_mode: { when: ->(**) { raise KeyError }, report: lambda { |error:, **|
        raise IOError, error.class.name
      } })

      expect(klass.call(text: "site down").priority).to eq("high")
      expect { sole(jobs).call }.not_to raise_error
    end

    it "drops the run, logged, when the runner refuses the job, and still returns the Ruby result" do
      io = StringIO.new
      Squishling.configure do |c|
        c.logger = Logger.new(io)
        c.apprentice_runner = ->(_job) { raise ThreadError, "pool full" }
      end

      expect(klass.call(text: "site down").priority).to eq("high")
      expect(io.string).to include("Triage#call apprentice run dropped: the runner raised ThreadError")
    end

    it "fails Testing.reset! when background runs are still pending" do
      runner = Object.new.tap do |object|
        object.define_singleton_method(:call) { |_job| nil }
        object.define_singleton_method(:drain) { |timeout:| timeout.nil? }
      end
      Squishling.configure { |c| c.apprentice_runner = runner }
      real = FakeAdapter.new
      Squishling.configure { |c| c.adapter = real }
      Squishling::Testing.install

      expect { Squishling::Testing.reset! }.to raise_error(Squishling::Testing::SetupError, /still pending/)
      expect(Squishling.config.adapter).to be_a(Squishling::Testing::ForbiddenAdapter)
      expect(Squishling.config.adapter_override).to be_a(Squishling::Testing::ForbiddenAdapter)

      runner.define_singleton_method(:drain) { |**| true }
      Squishling::Testing.reset!
      expect(Squishling.config.adapter).to equal(real)
    end

    it "has nothing to drain inline" do
      expect(Squishling::Apprentice.drain).to be(true)
    end
  end

  describe "an observer that takes reviews" do
    let(:reviews) { [] }
    let(:observer) do
      log = reviews
      Object.new.tap do |observer|
        observer.define_singleton_method(:around) { |_call, &block| block.call }
        observer.define_singleton_method(:apprentice) { |review| log << review }
      end
    end

    before { Squishling.configure { |c| c.observer = observer } }

    it "is told the Ruby result and the verdict, never the model's output" do
      stub_llm({ "priority" => "low" })

      klass.call(text: "site down")

      review = sole(reviews)
      expect(review).to have_attributes(label: "Triage#call", ruby: { "priority" => "high" }, match: false, error: nil,
        call_id: sole(reports)[:metadata][:call_id], request_id: sole(reports)[:metadata][:request_id])
      expect(review.to_h.inspect).not_to include("low")
    end

    it "is told when the shadow run failed" do
      stub_llm(Squishling::LLMError.new("rate limited"))

      klass.call(text: "site down")

      expect(sole(reviews)).to have_attributes(match: nil, request_id: nil, error: Squishling::LLMError)
    end

    it "is told only the class of an error that carries the model's output" do
      stub_llm({ "priority" => "SECRET_OUTPUT_2" }.merge("extra" => 1))

      klass.call(text: "site down")

      expect(sole(reviews).error).to eq(Squishling::InvalidOutputError)
      expect(sole(reviews).to_h.inspect).not_to include("SECRET_OUTPUT_2")
    end
  end

  describe "the request that produced the result" do
    it "is the accepted attempt's, after a retry" do
      klass.squishling(escalation: [{ model: "test-model", attempts: 2 }])
      stub_llm({ "priority" => 1 }, high)

      klass.call(text: "site down")

      metadata = sole(reports)[:metadata]
      expect(metadata[:request_id]).to eq("#{metadata[:call_id]}.2")
    end

    it "is the picked sample's, on a judged squishsum" do
      klass.squishling(harness: :judged_squishsum, escalation: %w[model-a model-b])
      stub_llm_chats([low], [high], [{ "verdict" => "b", "reason" => "outage" }])
      observed = []
      Squishling.configure do |c|
        c.observer = Object.new.tap do |o|
          o.define_singleton_method(:around) { |call, &block| block.call.tap { observed << call } }
        end
      end

      klass.call(text: "site down")

      sample_b = observed.find { |call| call.sample == "b" }
      expect(sole(reports)[:metadata][:request_id]).to eq(sample_b.request_id)
      expect(observed.map(&:request_id).uniq.size).to eq(3)
      expect(observed.map(&:apprentice).uniq).to eq([true])
    end
  end

  describe "verifying" do
    it "accepts a compare: lambda that takes the inputs as a third positional Hash" do
      positional = squishling_class do
        squishling model: "test-model", purpose: "Classify.",
          apprentice_mode: { compare: ->(ruby, llm, inputs) { ruby == llm && inputs.key?(:text) } }
        output_schema { string :priority }
        def call(text:) = { priority: text }
      end

      expect(Squishling.verify(positional).problems).to be_empty
    end

    it "leaves a class's LLM-only methods alone" do
      mixed = squishling_class do
        squishling model: "test-model", purpose: "Classify.", apprentice_mode: true
        squish :summarize do
          string :summary
        end
        output_schema { string :priority }
        def call = { priority: "low" }
      end

      expect(Squishling.verify(mixed).problems).to be_empty
    end

    it "flags a method without a Ruby implementation, and when: or compare: that can't take the inputs" do
      broken = squishling_class do
        def self.to_s = "Broken"
        squishling model: "test-model", purpose: "Classify."
        squish :call, apprentice_mode: { when: ->(missing:) { missing }, compare: ->(a, b) { a == b } } do
          string :priority
        end
        squish :ghost, apprentice_mode: true do
          string :priority
        end
        squish :other, apprentice_mode: { compare: ->(**) { true } } do
          string :priority
        end
        def call(text:) = { priority: text }
        def other(text:) = { priority: text }
      end

      messages = Squishling.verify(broken).problems.map { |problem| "#{problem.label} #{problem.message}" }

      expect(messages).to include(
        "Broken#call apprentice_mode when: requires missing:, which is not an input of the method",
        "Broken#call apprentice_mode compare: doesn't take the method's inputs as keywords (add **)",
        "Broken#other apprentice_mode compare: doesn't take the two results (the Ruby result and the LLM's) as " \
        "positional arguments",
        "Broken#ghost apprentice_mode: has no Ruby implementation to run alongside the LLM"
      )
    end
  end
end
