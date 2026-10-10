# frozen_string_literal: true

require "logger"
require "stringio"

RSpec.describe "Squishling harnesses" do
  let(:klass) do
    Class.new do
      include Squishling

      squishling escalation: [{ model: "claude-haiku-4-5", attempts: 2 }, "claude-sonnet-5-5"]
      purpose "Triage the ticket."
      output_schema do
        string :priority
        string :team
      end
    end
  end

  let(:high) { { "priority" => "high", "team" => "api" } }
  let(:low) { { "priority" => "low", "team" => "api" } }

  describe "declaring a harness" do
    it "defaults to escalation" do
      chats = stub_llm(high)

      expect(klass.call(text: "x").priority).to eq("high")
      expect(chats.size).to eq(1)
    end

    it "accepts a type as a Symbol, a String, or a Hash with type:" do
      expect(Squishling::Harness.normalize(:squishsum, "X").type).to eq(:squishsum)
      expect(Squishling::Harness.normalize("judged_squishsum", "X")).to be_judged
      expect(Squishling::Harness.normalize({ "type" => "squishsum" }, "X")).to be_squishsum
    end

    it "rejects unknown types and options" do
      expect { klass.squishling(harness: :majority) }.to raise_error(Squishling::ConfigurationError, /unknown harness/)
      expect { klass.squishling(harness: { type: :squishsum, rounds: 3 }) }
        .to raise_error(Squishling::ConfigurationError, /unknown harness option\(s\) rounds/)
      expect { klass.squishling(harness: { judge: "x" }) }.to raise_error(Squishling::ConfigurationError, /needs type:/)
      expect { klass.squishling(harness: 3) }.to raise_error(Squishling::ConfigurationError, /harness must be one of/)
      expect { klass.squishling(harness: false) }
        .to raise_error(Squishling::ConfigurationError, /harness must be one of/)
      expect { klass.squish(:triage, harness: false) { string :team } }
        .to raise_error(Squishling::ConfigurationError, /harness must be one of/)
      expect { klass.squishling_definition(:call).for_call(harness: false) }
        .to raise_error(Squishling::ConfigurationError, /squish!: harness must be one of/)
    end

    it "rejects options that don't apply to the type" do
      expect { klass.squishling(harness: { type: :squishsum, judge: "claude-opus-5-5" }) }
        .to raise_error(Squishling::ConfigurationError,
          /: judge: can only be used with the judged_squishsum and judged_ensemble/)
      expect { klass.squishling(harness: { type: :escalation, compare: ->(*) { true } }) }
        .to raise_error(Squishling::ConfigurationError, /compare: only applies to the sampling harnesses/)
      expect { klass.squishling(harness: { type: :squishsum, compare: :== }) }
        .to raise_error(Squishling::ConfigurationError, /compare: must be a Proc/)
      expect { klass.squishling(harness: { type: :judged_squishsum, judge_instructions: " " }) }
        .to raise_error(Squishling::ConfigurationError, /judge_instructions: must be a non-blank String/)
    end

    it "validates the judge step" do
      expect { klass.squishling(harness: { type: :judged_squishsum, judge: { model: "jev-latest", type: :vote } }) }
        .to raise_error(Squishling::ConfigurationError, /type: must be one of chat, judgment/)
      expect do
        klass.squishling(harness: { type: :judged_squishsum, judge: { model: "jev-latest", type: :judgment,
                                                                      min_confidence: 1.5 } })
      end.to raise_error(Squishling::ConfigurationError, /min_confidence: must be a number from 0 to 1/)
      expect { klass.squishling(harness: { type: :judged_squishsum, judge: { model: "x", min_confidence: 0.5 } }) }
        .to raise_error(Squishling::ConfigurationError, /only applies to type: :judgment judges/)
      expect { klass.squishling(harness: { type: :judged_squishsum, judge: { model: "x", order: 1 } }) }
        .to raise_error(Squishling::ConfigurationError, /takes no order:/)
      expect { klass.squishling(harness: { type: :judged_squishsum, judge: false }) }
        .to raise_error(Squishling::ConfigurationError, /judge: each step must be a model name or a Hash/)
      expect { klass.squishling(harness: { type: :judged_squishsum, judge: { model: "x", attempts: 0 } }) }
        .to raise_error(Squishling::ConfigurationError, /attempts: must be a positive Integer/)
    end

    it "resolves squish! over the method over the class over the configured default" do
      Squishling.configure { |c| c.default_harness = :squishsum }
      expect(klass.squishling_definition(:call).harness.type).to eq(:squishsum)

      klass.squishling(harness: :judged_squishsum)
      expect(klass.squishling_definition(:call).harness.type).to eq(:judged_squishsum)

      klass.squish(:call, harness: :escalation)
      definition = klass.squishling_definition(:call)
      expect(definition.harness.type).to eq(:escalation)
      expect(definition.for_call(harness: :squishsum).harness.type).to eq(:squishsum)
      expect(definition.for_call.harness.type).to eq(:escalation)
    end

    it "is inherited by subclasses" do
      klass.squishling(harness: :squishsum)

      expect(Class.new(klass).squishling_definition(:call).harness.type).to eq(:squishsum)
    end

    it "validates the configured default on assignment" do
      expect { Squishling.configure { |c| c.default_harness = :best_of_three } }
        .to raise_error(Squishling::ConfigurationError, /default_harness: unknown harness/)
    end
  end

  describe "squishsum" do
    before { klass.squishling(harness: :squishsum) }

    it "accepts identical samples from two chats on the first escalation step" do
      chats = stub_llm_chats([high], [high])

      result = klass.call(text: "x")

      expect(result.to_h).to eq(priority: "high", team: "api")
      expect(result).to be_squished
      expect(chats.map(&:model)).to eq(%w[claude-haiku-4-5 claude-haiku-4-5])
      expect(chats.map(&:messages)).to all(eq([JSON.generate(arguments: { text: "x" })]))
    end

    it "sends the two requests concurrently" do
      lock = Mutex.new
      arrived = ConditionVariable.new
      waiting = 0
      overlapped = []
      barrier = lambda do |_chat|
        lock.synchronize do
          waiting += 1
          arrived.broadcast
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
          while waiting < 2 && (remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)).positive?
            arrived.wait(lock, remaining)
          end
          overlapped << (waiting >= 2)
        end
      end
      stub_llm_chats([high], [high], on_ask: barrier)

      klass.call(text: "x")

      expect(overlapped).to eq([true, true])
    end

    it "carries RubyLLM's instrumentation workflow over to the request threads" do
      seen = Queue.new
      stub_llm_chats([high], [high], on_ask: lambda { |_chat|
        seen << [Thread.current, RubyLLM::Support::Instrumentation.current_workflow]
      })

      RubyLLM::Support::Instrumentation.with_workflow({ name: "triage" }) { klass.call(text: "x") }

      requests = [seen.pop, seen.pop]
      expect(requests.map(&:first)).not_to include(Thread.current)
      expect(requests.map(&:last)).to eq([{ name: "triage" }] * 2)
    end

    it "carries instrumentation subscribers' context over to the request threads" do
      subscriber = Object.new
      subscriber.define_singleton_method(:capture_context) { Thread.current[:squishling_spec_span] }
      subscriber.define_singleton_method(:with_context) do |span, &block|
        Thread.current[:squishling_spec_span] = span
        block.call
      ensure
        Thread.current[:squishling_spec_span] = nil
      end
      subscriber.define_singleton_method(:instrument) { |_name, _payload, &block| block.call }
      seen = Queue.new
      stub_llm_chats([high], [high], on_ask: ->(_chat) { seen << Thread.current[:squishling_spec_span] })
      RubyLLM::Support::Instrumentation.subscribe(subscriber)
      Thread.current[:squishling_spec_span] = "span-1"

      klass.call(text: "x")

      expect([seen.pop, seen.pop]).to eq(%w[span-1 span-1])
    ensure
      Thread.current[:squishling_spec_span] = nil
      RubyLLM::Support::Instrumentation.unsubscribe(subscriber)
    end

    it "stops the requests still running when the caller is interrupted" do
      started = Queue.new
      stub_llm_chats([high], [high], on_ask: lambda { |_chat|
        started << Thread.current
        sleep
      })
      caller = Thread.new { klass.call(text: "x") }.tap { |thread| thread.report_on_exception = false }
      workers = [started.pop, started.pop]

      caller.raise(Interrupt)
      expect { caller.join }.to raise_error(Interrupt)
      expect(workers.map(&:alive?)).to eq([false, false])
    end

    it "raises DisagreementError with both typed candidates when the samples differ" do
      stub_llm_chats([high], [low])

      expect { klass.call(text: "x") }.to raise_error(Squishling::DisagreementError) do |e|
        expect(e).to be_a(Squishling::InvalidOutputError)
        expect(e.candidates.map(&:priority)).to eq(%w[high low])
        expect(e.candidates).to all(be_squished)
        expect(e.verdict).to be_nil
        expect(e.errors).to eq(["the two samples disagreed"])
        expect(e.raw).to eq([{ priority: "high", team: "api" }, { priority: "low", team: "api" }])
        expect(e.models).to eq(%w[claude-haiku-4-5 claude-haiku-4-5])
      end
    end

    it "hands a disagreement to squish_fallback" do
      klass.squish_fallback { |error, **| error.candidates.last }
      stub_llm_chats([high], [low])

      expect(klass.call(text: "x").priority).to eq("low")
    end

    it "uses compare: to decide agreement, evaluated against the instance with the inputs" do
      klass.squishling(harness: { type: :squishsum, compare: ->(a, b, text:) { a.team == b.team && text == "x" } })
      stub_llm_chats([high], [low])

      expect(klass.call(text: "x").priority).to eq("high")
    end

    it "lets an exception raised by compare: propagate unwrapped, without the fallback" do
      fallback = []
      klass.squish_fallback { |error, **| fallback << error }
      klass.squishling(harness: { type: :squishsum, compare: ->(*) { raise ArgumentError, "boom" } })
      stub_llm_chats([high], [low])

      expect { klass.call(text: "x") }.to raise_error(ArgumentError, "boom")
      expect(fallback).to be_empty
    end

    it "retries an invalid sample in its own chat while keeping the other's result" do
      chats = stub_llm_chats([{ "priority" => 1, "team" => "api" }, high], [high])

      expect(klass.call(text: "x").priority).to eq("high")
      expect(chats.size).to eq(2)
      expect(chats.first.messages.size).to eq(2)
      expect(chats.first.messages.last).to include("Your previous response was rejected")
      expect(chats.last.messages.size).to eq(1)
    end

    it "runs squish_validate on each sample, on the caller's thread" do
      threads = []
      klass.squish_validate do |result, **|
        threads << Thread.current
        "team must be api" unless result.team == "api"
      end
      chats = stub_llm_chats([high], [{ "priority" => "high", "team" => "web" }, high])

      expect(klass.call(text: "x").priority).to eq("high")
      expect(chats.last.messages.last).to include("team must be api")
      expect(threads.uniq).to eq([Thread.current])
    end

    it "starts a fresh chat for a sample after a failed request" do
      chats = stub_llm_chats([RubyLLM::ServerError.new("boom")], [high], [high])

      expect(klass.call(text: "x").priority).to eq("high")
      expect(chats.size).to eq(3)
    end

    it "raises InvalidOutputError when a sample is still invalid after the step's attempts" do
      invalid = { "priority" => 1, "team" => "api" }
      chats = stub_llm_chats([invalid, invalid], [high])

      expect { klass.call(text: "x") }.to raise_error(Squishling::InvalidOutputError) do |e|
        expect(e).not_to be_a(Squishling::DisagreementError)
        expect(e.attempts).to eq(2)
        expect(e.models).to eq(%w[claude-haiku-4-5 claude-haiku-4-5])
      end
      expect(chats.map(&:model)).not_to include("claude-sonnet-5-5")
    end

    it "raises LLMError when a sample's last attempt fails" do
      stub_llm_chats([high], [RubyLLM::ServerError.new("boom")], [RubyLLM::ServerError.new("again")])

      expect { klass.call(text: "x") }.to raise_error(Squishling::LLMError, /again/)
    end

    it "raises a provider 400 as a ConfigurationError, never handing it to the fallback" do
      fallback = []
      klass.squish_fallback { |error, **| fallback << error }
      stub_llm_chats([high], [RubyLLM::BadRequestError.new("bad temperature")])

      expect { klass.call(text: "x") }.to raise_error(Squishling::ConfigurationError, /bad temperature/)
      expect(fallback).to be_empty
    end

    it "logs the disagreement" do
      log = StringIO.new
      Squishling.configure { |c| c.logger = Logger.new(log) }
      stub_llm_chats([high], [low])

      expect { klass.call(text: "x") }.to raise_error(Squishling::DisagreementError)
      expect(log.string).to include("samples disagreed")
    end

    it "can be chosen for one call with squish!" do
      klass.squishling(harness: :escalation)
      klass.define_method(:call) { |text:| squish!(harness: :squishsum, context: { length: text.size }) }
      chats = stub_llm_chats([high], [high])

      expect(klass.call(text: "x").priority).to eq("high")
      expect(chats.size).to eq(2)
    end

    it "calls squawk for every sample attempt, with the rejection as the error" do
      calls = []
      klass.squishling(squawk: ->(output:, metadata:, error:) { calls << [output, metadata, error] })
      invalid = { "priority" => 1, "team" => "api" }
      stub_llm_chats([invalid, high], [high])

      klass.call(text: "x")

      expect(calls.map { |output, _, error| [output, error&.class] })
        .to contain_exactly([invalid, Squishling::InvalidOutputError], [high, nil], [high, nil])
      expect(calls.map { |_, metadata, _| metadata[:attempts] }).to all(eq(2))
      expect(calls.map { |_, metadata, _| metadata[:final] }).to contain_exactly(false, false, true)
    end

    it "calls squawk with the LLMError when a sample's request fails, then with the retry's output" do
      calls = []
      klass.squishling(squawk: ->(output:, error:, **) { calls << [output, error&.class] })
      stub_llm_chats([RubyLLM::ServerError.new("boom")], [high], [high])

      klass.call(text: "x")

      expect(calls).to contain_exactly([nil, Squishling::LLMError], [high, nil], [high, nil])
    end

    it "starts a sample's fresh chat from the input alone when the step sets forward_rejected: false" do
      invalid = { "priority" => 1, "team" => "api" }
      responses = [[invalid, RubyLLM::ServerError.new("boom")], [high], [high]]

      [true, false].each do |forward|
        klass.squishling(escalation: [{ model: "claude-haiku-4-5", attempts: 3, forward_rejected: forward }])
        chats = stub_llm_chats(*responses)

        klass.call(text: "x")

        input = JSON.generate(arguments: { text: "x" })
        expect(chats.last.messages.first).to forward ? include("A previous attempt") : eq(input)
      end
    end
  end

  describe "judged_squishsum" do
    before { klass.squishling(harness: :judged_squishsum) }

    it "calls squawk for the judge's attempt too, with the judge's own input" do
      calls = []
      klass.squishling(squawk: ->(metadata:, **) { calls << metadata })
      stub_llm_chats([high], [low], [{ "verdict" => "a", "reason" => "more urgent" }])

      klass.call(text: "x")

      expect(calls.size).to eq(3)
      expect(calls.last).to include(model: "claude-sonnet-5-5", final: true)
      expect(JSON.parse(calls.last[:input])).to include("candidates")
    end

    it "doesn't call the judge when the samples agree" do
      chats = stub_llm_chats([high], [high])

      expect(klass.call(text: "x").priority).to eq("high")
      expect(chats.size).to eq(2)
    end

    it "asks the escalation's next step to judge, and returns the candidate it picks" do
      chats = stub_llm_chats([high], [low], [{ "verdict" => "b", "reason" => "routine ticket" }])

      result = klass.call(text: "x")

      expect(result.priority).to eq("low")
      expect(result).to be_squished
      expect(chats.last.model).to eq("claude-sonnet-5-5")
    end

    it "runs squish_validate on the samples but not on the judge's verdict" do
      validated = []
      klass.squish_validate do |result, **|
        validated << result.priority
        "team must be api" unless result.team == "api"
      end
      chats = stub_llm_chats([high], [low], [{ "verdict" => "b", "reason" => "routine ticket" }])

      expect(klass.call(text: "x").priority).to eq("low")
      expect(validated).to eq(%w[high low])
      expect(chats.last.messages.size).to eq(1)
    end

    it "gives the judge the operation's purpose, the input, the output schema, and both candidates" do
      chats = stub_llm_chats([high], [low], [{ "verdict" => "a", "reason" => "outage" }])

      klass.call(text: "x")

      judge = chats.last
      expect(judge.instructions).to start_with(Squishling::Harness::DEFAULT_JUDGE_INSTRUCTIONS)
      expect(judge.instructions).to include("<purpose>\nTriage the ticket.\n</purpose>")
      expect(judge.schema).to eq(Squishling::Schema.for(Squishling::Judge::VERDICT_SCHEMA).llm_schema)
      message = JSON.parse(judge.messages.first)
      expect(message["input"]).to eq("arguments" => { "text" => "x" })
      expect(message["output_schema"]["properties"].keys).to eq(%w[priority team])
      expect(message["candidates"]).to eq("a" => high, "b" => low)
    end

    it "raises DisagreementError with the judge's reason when it picks neither" do
      stub_llm_chats([high], [low], [{ "verdict" => "neither", "reason" => "both misread the ticket" }])

      expect { klass.call(text: "x") }.to raise_error(Squishling::DisagreementError) do |e|
        expect(e.verdict).to eq(:neither)
        expect(e.reason).to eq("both misread the ticket")
        expect(e.message).to include("the judge rejected both samples (both misread the ticket)")
        expect(e.models).to eq(%w[claude-haiku-4-5 claude-haiku-4-5 claude-sonnet-5-5])
      end
    end

    it "retries an invalid verdict per the judge step's attempts, then raises InvalidOutputError" do
      klass.squishling(escalation: ["claude-haiku-4-5", { model: "claude-sonnet-5-5", attempts: 2 }])
      chats = stub_llm_chats([high], [low], [{ "verdict" => "c", "reason" => "?" }, { "verdict" => "d" }])

      expect { klass.call(text: "x") }.to raise_error(Squishling::InvalidOutputError, /Judge output was invalid/)
      expect(chats.last.messages.size).to eq(2)
    end

    it "uses a dedicated judge: step with its own model, its params merged over the method's" do
      klass.squishling(params: { temperature: 0.1, seed: 7 },
        harness: { type: :judged_squishsum, judge: { model: "claude-opus-5-5", params: { top_p: 1, seed: 9 } } })
      chats = stub_llm_chats([high], [low], [{ "verdict" => "a", "reason" => "outage" }])

      expect(klass.call(text: "x").priority).to eq("high")
      expect(chats.last.model).to eq("claude-opus-5-5")
      expect(chats.last.generation).to include(temperature: 0.1, provider_options: { seed: 9, top_p: 1 })
    end

    it "gives a judge: step only its own provider:, never the class's" do
      klass.squishling(provider: :anthropic, harness: { type: :judged_squishsum, judge: "claude-opus-5-5" })
      chats = stub_llm_chats([high], [low], [{ "verdict" => "a", "reason" => "outage" }])

      klass.call(text: "x")

      expect(chats.first.options).to include(provider: :anthropic)
      expect(chats.last.options).not_to include(:provider)

      klass.squishling(harness: { type: :judged_squishsum, judge: { model: "gpt-unknown", provider: :openai } })
      chats = stub_llm_chats([high], [low], [{ "verdict" => "a", "reason" => "outage" }])

      klass.call(text: "x")

      expect(chats.last.options).to eq(provider: :openai, assume_model_exists: true)
    end

    it "replaces the default judge prompt with judge_instructions:, a String or a Proc against the instance" do
      klass.define_method(:strictness) { "Prefer the higher priority." }
      klass.squishling(harness: { type: :judged_squishsum, judge_instructions: -> { strictness } })
      chats = stub_llm_chats([high], [low], [{ "verdict" => "a", "reason" => "higher" }])

      klass.call(text: "x")

      expect(chats.last.instructions).to start_with("Prefer the higher priority.")
      expect(chats.last.instructions).not_to include(Squishling::Harness::DEFAULT_JUDGE_INSTRUCTIONS)
    end

    it "raises ConfigurationError when a judge_instructions proc returns nothing" do
      klass.squishling(harness: { type: :judged_squishsum, judge_instructions: -> {} })
      stub_llm_chats([high], [low])

      expect { klass.call(text: "x") }
        .to raise_error(Squishling::ConfigurationError, /judge_instructions proc must return a non-blank String/)
    end

    it "needs a judge: or a second escalation step, checked before any sample is requested" do
      klass.squishling(model: "claude-haiku-4-5")
      chats = stub_llm_chats

      expect { klass.call(text: "x") }
        .to raise_error(Squishling::ConfigurationError, /needs a judge: or a second escalation step/)
      expect(chats).to be_empty
    end

    it "raises LLMError when the chat judge's last attempt fails, which goes to squish_fallback" do
      klass.squish_fallback { |error, **| error.is_a?(Squishling::LLMError) ? { priority: "medium", team: "api" } : raise }
      stub_llm_chats([high], [low], [RubyLLM::ServerError.new("judge down")])

      result = klass.call(text: "x")

      expect(result.priority).to eq("medium")
      expect(result).not_to be_squished
    end

    it "hands a rejection to squish_fallback with both candidates" do
      klass.squish_fallback { |error, **| error.candidates.first }
      stub_llm_chats([high], [low], [{ "verdict" => "neither", "reason" => "unsure" }])

      expect(klass.call(text: "x").priority).to eq("high")
    end

    describe "with a System One judgment model" do
      let(:jev) { { model: "jev-latest", type: :judgment, min_confidence: 0.8 } }

      before { klass.squishling(harness: { type: :judged_squishsum, judge: jev }) }

      it "accepts the pick at or above min_confidence" do
        stub_llm_chats([high], [low])
        calls = stub_judgment({ choice: :b, probabilities: { a: 0.05, b: 0.9, neither: 0.05 } })

        expect(klass.call(text: "x").priority).to eq("low")
        call = calls.first
        expect(call[:options]).to include(model: "jev-latest")
        expect(call[:questions][:winner]).to include(type: :choice, options: Squishling::Judge::CHOICES)
        expect(call[:questions][:winner][:instructions]).to eq(Squishling::Harness::DEFAULT_JUDGE_INSTRUCTIONS)
        expect(call[:input]).to include(purpose: "Triage the ticket.", candidates: { a: high, b: low })
      end

      it "builds a judgment RubyLLM's own Judge accepts: one choice question and the judgment input" do
        klass.squishling(harness: { type: :judged_squishsum, judge: jev.merge(params: { reasoning: "fast" }) })
        stub_llm_chats([high], [low])
        received = {}
        # Stubbed below RubyLLM.judge, so RubyLLM's own question and input validation runs.
        allow(RubyLLM::Judgment).to receive(:judge) do |input, questions:, **settings|
          received.merge!(input:, questions:, settings:)
          choice = RubyLLM::Choice.new(choice: :b, probabilities: { a: 0.1, b: 0.85, neither: 0.05 }, confidence: 0.85)
          RubyLLM::Judgment.new(answers: { winner: choice }, model: "jev-latest")
        end

        expect(klass.call(text: "x").priority).to eq("low")
        winner = received[:questions].fetch("winner")
        expect(winner.type).to eq(:choice)
        expect(winner.criteria.keys).to eq(%i[a b neither])
        expect(winner.instructions).to eq(Squishling::Harness::DEFAULT_JUDGE_INSTRUCTIONS)
        expect(received[:input]).to include(purpose: "Triage the ticket.", candidates: { a: high, b: low })
        expect(received[:settings]).to include(model: "jev-latest", provider_options: { reasoning: "fast" })
      end

      it "raises ConfigurationError, without retrying, for a judgment model RubyLLM doesn't know" do
        fallback = []
        klass.squish_fallback { |e, **| fallback << e }
        klass.squishling(harness: { type: :judged_squishsum, judge: jev.merge(model: "jev-nonexistent", attempts: 2) })
        stub_llm_chats([high], [low])
        calls = stub_judgment(RubyLLM::ModelNotFoundError.new("Unknown model: jev-nonexistent"))

        expect { klass.call(text: "x") }
          .to raise_error(Squishling::ConfigurationError, /Unknown model: jev-nonexistent/)
        expect(calls.size).to eq(1)
        expect(fallback).to be_empty
      end

      it "rejects a pick below min_confidence" do
        stub_llm_chats([high], [low])
        stub_judgment({ choice: :a, probabilities: { a: 0.6, b: 0.3, neither: 0.1 } })

        expect { klass.call(text: "x") }.to raise_error(Squishling::DisagreementError) do |e|
          expect(e.reason).to include("below min_confidence 0.8")
        end
      end

      it "accepts a pick whose probability equals min_confidence" do
        stub_llm_chats([high], [low])
        stub_judgment({ choice: :a, probabilities: { a: 0.8, b: 0.2 } })

        expect(klass.call(text: "x").priority).to eq("high")
      end

      it "compares the exact probability, not a rounded one, against min_confidence" do
        stub_llm_chats([high], [low])
        stub_judgment({ choice: :a, probabilities: { a: 0.7996, b: 0.2004 } })

        expect { klass.call(text: "x") }.to raise_error(Squishling::DisagreementError, /below min_confidence 0.8/)
      end

      it "raises LLMError once failed judgment requests use up the judge's attempts" do
        klass.squishling(harness: { type: :judged_squishsum, judge: jev.merge(attempts: 2) })
        stub_llm_chats([high], [low])
        calls = stub_judgment(RubyLLM::ServerError.new("busy"), RubyLLM::ServerError.new("still busy"))

        expect { klass.call(text: "x") }.to raise_error(Squishling::LLMError, /still busy/)
        expect(calls.size).to eq(2)
      end

      it "rejects when the judgment picks neither" do
        stub_llm_chats([high], [low])
        stub_judgment({ choice: :neither, probabilities: { a: 0.1, b: 0.1, neither: 0.8 } })

        expect { klass.call(text: "x") }.to raise_error(Squishling::DisagreementError, /chose neither/)
      end

      it "sends only the judge's own params, as provider options" do
        klass.squishling(params: { temperature: 0.1 },
          harness: { type: :judged_squishsum, judge: jev.merge(params: { reasoning: "fast" }) })
        stub_llm_chats([high], [low])
        calls = stub_judgment({ choice: :a, probabilities: { a: 0.9, b: 0.05, neither: 0.05 } })

        klass.call(text: "x")

        expect(calls.first[:options][:provider_options]).to eq(reasoning: "fast")
      end

      it "retries a failed judgment request per the judge's attempts" do
        klass.squishling(harness: { type: :judged_squishsum, judge: jev.merge(attempts: 2) })
        stub_llm_chats([high], [low])
        stub_judgment(RubyLLM::ServerError.new("busy"), { choice: :a, probabilities: { a: 0.9, b: 0.1 } })

        expect(klass.call(text: "x").priority).to eq("high")
      end

      it "raises ConfigurationError, never handing it to the fallback, when the provider doesn't support judgments" do
        fallback = []
        klass.squish_fallback { |error, **| fallback << error }
        klass.squishling(harness: { type: :judged_squishsum, judge: jev.merge(attempts: 2) })
        stub_llm_chats([high], [low])
        calls = stub_judgment(RubyLLM::Error.new("Anthropic doesn't support judgments"))

        expect { klass.call(text: "x") }.to raise_error(Squishling::ConfigurationError, /doesn't support judgments/)
        expect(calls.size).to eq(1)
        expect(fallback).to be_empty
      end

      it "raises InvalidOutputError when the judgment has no winner answer" do
        stub_llm_chats([high], [low])
        allow(RubyLLM).to receive(:judge).and_return(RubyLLM::Judgment.new(answers: {}, model: "jev-latest"))

        expect { klass.call(text: "x") }
          .to raise_error(Squishling::InvalidOutputError, /Judge output was invalid: the judgment didn't answer/)
      end

      it "maps an ArgumentError raised inside RubyLLM (a judgment it can't build) to ConfigurationError" do
        stub_llm_chats([high], [low])
        ruby_llm_lib = File.dirname(RubyLLM.method(:judge).source_location.first)
        error = ArgumentError.new("judge does not accept a model")
        error.set_backtrace(["#{ruby_llm_lib}/ruby_llm/models.rb:193:in 'resolve'"])
        stub_judgment(error)

        expect { klass.call(text: "x") }.to raise_error(Squishling::ConfigurationError, /does not accept a model/)
      end

      it "lets an ArgumentError from the developer's own code (e.g. a subscriber) propagate unwrapped" do
        fallback = []
        klass.squish_fallback { |e, **| fallback << e }
        stub_llm_chats([high], [low])
        stub_judgment(ArgumentError.new("subscriber bug"))

        expect { klass.call(text: "x") }.to raise_error(ArgumentError, "subscriber bug")
        expect(fallback).to be_empty
      end

      it "rejects judge params that RubyLLM's judgment protocols reserve" do
        expect { klass.squishling(harness: { type: :judged_squishsum, judge: jev.merge(params: { state: "x" }) }) }
          .to raise_error(Squishling::ConfigurationError, /state can't be set through params/)
      end
    end
  end

  describe "ensemble harnesses" do
    let(:ensemble_klass) do
      Class.new do
        include Squishling

        squishling escalation: [{ model: "claude-haiku-4-5", attempts: 2 }, "claude-sonnet-5-5", "claude-opus-5-5"],
          harness: :ensemble
        purpose "Triage the ticket."
        output_schema do
          string :priority
          string :team
        end
      end
    end
    let(:invalid) { { "priority" => "high" } }

    it "declares :ensemble and :judged_ensemble, with judge options only on the judged one" do
      expect { ensemble_klass.squishling(harness: { type: :judged_ensemble, judge: "claude-opus-5-5" }) }
        .not_to raise_error
      expect { ensemble_klass.squishling(harness: { type: :ensemble, compare: ->(*) { true } }) }.not_to raise_error
      expect { ensemble_klass.squishling(harness: { type: :ensemble, judge: "claude-opus-5-5" }) }
        .to raise_error(Squishling::ConfigurationError, /judge: can only be used with the judged_squishsum and/)
    end

    it "samples the first and second escalation steps, one chat each" do
      chats = stub_llm_chats([high], [high])

      result = ensemble_klass.call(text: "x")

      expect(result.to_h).to eq(priority: "high", team: "api")
      expect(chats.map(&:model)).to eq(%w[claude-haiku-4-5 claude-sonnet-5-5])
    end

    it "raises DisagreementError naming the model behind each sample when they differ" do
      stub_llm_chats([high], [low])

      expect { ensemble_klass.call(text: "x") }.to raise_error(Squishling::DisagreementError) do |error|
        expect(error.models).to eq(%w[claude-haiku-4-5 claude-sonnet-5-5])
        expect(error.candidates.map(&:priority)).to eq(%w[high low])
      end
    end

    it "uses compare: to decide agreement and returns the first sample" do
      ensemble_klass.squishling(harness: { type: :ensemble, compare: ->(a, b, **) { a.team == b.team } })
      stub_llm_chats([high], [low])

      expect(ensemble_klass.call(text: "x").priority).to eq("high")
    end

    it "retries each sample within its own step's attempts" do
      chats = stub_llm_chats([invalid, high], [high])

      expect(ensemble_klass.call(text: "x").priority).to eq("high")
      expect(chats.map(&:model)).to eq(%w[claude-haiku-4-5 claude-sonnet-5-5])
      expect(chats.first.messages.size).to eq(2)
    end

    it "fails with the second sample's models when its only attempt is invalid" do
      stub_llm_chats([high], [invalid])

      expect { ensemble_klass.call(text: "x") }.to raise_error(Squishling::InvalidOutputError) do |error|
        expect(error.models).to eq(%w[claude-sonnet-5-5])
        expect(error.attempts).to eq(1)
      end
    end

    it "reports each sample's own model and attempt count through squawk" do
      calls = []
      ensemble_klass.squishling(squawk: ->(metadata:, **) { calls << metadata })
      stub_llm_chats([invalid, high], [high])

      ensemble_klass.call(text: "x")

      expect(calls.map { |call| call.values_at(:model, :attempt, :attempts) })
        .to contain_exactly(["claude-haiku-4-5", 1, 2], ["claude-haiku-4-5", 2, 2], ["claude-sonnet-5-5", 1, 1])
    end

    it "retries the second sample alone when it has more attempts than the first" do
      ensemble_klass.squishling(escalation: ["claude-haiku-4-5", { model: "claude-sonnet-5-5", attempts: 2 }])
      chats = stub_llm_chats([high], [invalid, invalid])

      expect { ensemble_klass.call(text: "x") }.to raise_error(Squishling::InvalidOutputError) do |error|
        expect(error.models).to eq(%w[claude-sonnet-5-5 claude-sonnet-5-5])
        expect(error.attempts).to eq(2)
      end
      expect(chats.map(&:model)).to eq(%w[claude-haiku-4-5 claude-sonnet-5-5])
    end

    it "fails with the first sample's models when it uses up its attempts while the second already passed" do
      stub_llm_chats([invalid, invalid], [high])

      expect { ensemble_klass.call(text: "x") }.to raise_error(Squishling::InvalidOutputError) do |error|
        expect(error.models).to eq(%w[claude-haiku-4-5 claude-haiku-4-5])
        expect(error.attempts).to eq(2)
      end
    end

    it "starts a fresh chat for a sample whose request failed, while the other keeps its result" do
      chats = stub_llm_chats([high], [RubyLLM::ServerError.new("boom")], [high])
      ensemble_klass.squishling(escalation: ["claude-haiku-4-5", { model: "claude-sonnet-5-5", attempts: 2 }])

      expect(ensemble_klass.call(text: "x").priority).to eq("high")
      expect(chats.map(&:model)).to eq(%w[claude-haiku-4-5 claude-sonnet-5-5 claude-sonnet-5-5])
    end

    it "can be set as the default harness or chosen for one call with squish!" do
      Squishling.configure { |c| c.default_harness = :ensemble }
      plain = Class.new do
        include Squishling

        squishling escalation: %w[claude-haiku-4-5 claude-sonnet-5-5]
        purpose "Triage the ticket."
        output_schema { string :priority }
        define_method(:call) { |text:| squish!(harness: :ensemble, context: { length: text.size }) }
      end
      chats = stub_llm_chats([{ "priority" => "high" }], [{ "priority" => "high" }])

      expect(plain.call(text: "x").priority).to eq("high")
      expect(chats.map(&:model)).to eq(%w[claude-haiku-4-5 claude-sonnet-5-5])
      expect(plain.squishling_definition(:call).harness.type).to eq(:ensemble)
    end

    it "needs a second escalation step, checked before any request" do
      ensemble_klass.squishling(model: "claude-haiku-4-5")
      chats = stub_llm_chats

      expect { ensemble_klass.call(text: "x") }
        .to raise_error(Squishling::ConfigurationError, /ensemble harness needs a second escalation step/)
      expect(chats).to be_empty
    end

    describe "judged_ensemble" do
      before { ensemble_klass.squishling(harness: :judged_ensemble) }

      it "doesn't ask the judge when the samples agree" do
        chats = stub_llm_chats([high], [high])

        expect(ensemble_klass.call(text: "x").priority).to eq("high")
        expect(chats.size).to eq(2)
      end

      it "judges with the third escalation step and returns the candidate it picks" do
        chats = stub_llm_chats([high], [low], [{ "verdict" => "b", "reason" => "routine ticket" }])

        expect(ensemble_klass.call(text: "x").priority).to eq("low")
        expect(chats.map(&:model)).to eq(%w[claude-haiku-4-5 claude-sonnet-5-5 claude-opus-5-5])
      end

      it "lists every role's model when the judge picks neither" do
        stub_llm_chats([high], [low], [{ "verdict" => "neither", "reason" => "unclear" }])

        expect { ensemble_klass.call(text: "x") }.to raise_error(Squishling::DisagreementError) do |error|
          expect(error.verdict).to eq(:neither)
          expect(error.models).to eq(%w[claude-haiku-4-5 claude-sonnet-5-5 claude-opus-5-5])
        end
      end

      it "retries the default judge per its step's attempts" do
        ensemble_klass.squishling(escalation: ["claude-haiku-4-5", "claude-sonnet-5-5",
                                               { model: "claude-opus-5-5", attempts: 2 }])
        chats = stub_llm_chats([high], [low], [{ "verdict" => "bogus" }, { "verdict" => "a", "reason" => "urgent" }])

        expect(ensemble_klass.call(text: "x").priority).to eq("high")
        expect(chats.last.model).to eq("claude-opus-5-5")
      end

      it "takes a judge: when the escalation has only two steps" do
        ensemble_klass.squishling(escalation: %w[claude-haiku-4-5 claude-sonnet-5-5],
          harness: { type: :judged_ensemble, judge: "claude-opus-5-5" })
        chats = stub_llm_chats([high], [low], [{ "verdict" => "a", "reason" => "urgent" }])

        expect(ensemble_klass.call(text: "x").priority).to eq("high")
        expect(chats.last.model).to eq("claude-opus-5-5")
      end

      it "needs a judge: or a third escalation step, checked before any request" do
        ensemble_klass.squishling(escalation: %w[claude-haiku-4-5 claude-sonnet-5-5])
        chats = stub_llm_chats

        expect { ensemble_klass.call(text: "x") }
          .to raise_error(Squishling::ConfigurationError, /needs a judge: or a third escalation step/)
        expect(chats).to be_empty
      end
    end
  end
end
