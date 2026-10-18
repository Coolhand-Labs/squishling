# frozen_string_literal: true

require "logger"
require "stringio"

RSpec.describe "Squishling custom harnesses" do
  let(:klass) do
    Class.new do
      include Squishling

      squishling escalation: ["claude-haiku-4-5", "claude-sonnet-5-5"]
      purpose "Triage the ticket."
      output_schema do
        string :priority
        string :team
      end
    end
  end

  let(:high) { { "priority" => "high", "team" => "api" } }
  let(:low) { { "priority" => "low", "team" => "api" } }

  # Two cheap models, and a third to break the tie: the docs' worked example.
  let(:tiebreaker) do
    Class.new(Squishling::Harness::Base) do
      option :tiebreaker, :step, required: true
      option :compare, :proc

      def call(run, tiebreaker:, compare: nil)
        first, second = run.samples(run.stages.first(2))
        return first if run.agree?(first, second, compare)

        run.escalate(tiebreaker)
      end
    end
  end

  describe "registering" do
    it "registers a Harness::Base subclass, returning it" do
      expect(Squishling.register_harness(:tiebreaker, tiebreaker)).to equal(tiebreaker)
      expect(Squishling.harnesses).to eq(%i[escalation squishsum judged_squishsum tiebreaker])
    end

    it "registers a block as the body of a Harness::Base subclass" do
      registered = Squishling.register_harness(:majority) do
        option :rounds, :integer

        def call(run, rounds: 1)
          run.samples([run.stages.first] * (rounds + 1)).first
        end
      end

      expect(registered.superclass).to equal(Squishling::Harness::Base)
      expect(registered.options.keys).to eq([:rounds])
      expect(Squishling::Harness.normalize({ type: :majority, rounds: 2 }, "X").options).to eq(rounds: 2)
    end

    it "accepts the name as a String" do
      Squishling.register_harness("tiebreaker", tiebreaker)

      expect(Squishling.harnesses).to include(:tiebreaker)
      expect(Squishling::Harness.normalize({ type: :tiebreaker, tiebreaker: "x" }, "X").type).to eq(:tiebreaker)
    end

    it "rejects a name that is taken, including the built-ins" do
      Squishling.register_harness(:tiebreaker, tiebreaker)

      expect { Squishling.register_harness(:tiebreaker, tiebreaker) }
        .to raise_error(Squishling::ConfigurationError, /harness :tiebreaker is already registered/)
      %i[escalation squishsum judged_squishsum].each do |built_in|
        expect { Squishling.register_harness(built_in, tiebreaker) }
          .to raise_error(Squishling::ConfigurationError, /harness :#{built_in} is already registered/)
      end
    end

    it "rejects a name that isn't lowercase letters, digits, and underscores" do
      ["Two Samples", "2fast", "", :"a-b", nil, 3].each do |name|
        expect { Squishling.register_harness(name, tiebreaker) }.to raise_error(Squishling::ConfigurationError, /name/)
      end
    end

    it "needs a class or a block, not both" do
      expect { Squishling.register_harness(:nothing) }
        .to raise_error(Squishling::ConfigurationError, /needs a Harness::Base subclass or a block/)
      expect { Squishling.register_harness(:both, tiebreaker) { nil } }
        .to raise_error(Squishling::ConfigurationError, /a class or a block, not both/)
    end

    it "rejects a class that isn't a Harness::Base subclass, or is Harness::Base itself" do
      [Class.new, "tiebreaker", Squishling::Harness::Base].each do |bad|
        expect { Squishling.register_harness(:bad, bad) }
          .to raise_error(Squishling::ConfigurationError, /must be a subclass of Squishling::Harness::Base/)
      end
    end

    it "rejects a harness without call" do
      expect { Squishling.register_harness(:bad, Class.new(Squishling::Harness::Base)) }
        .to raise_error(Squishling::ConfigurationError, /must define call\(run, \*\*options\)/)
    end

    it "rejects a call that isn't public" do
      expect do
        Squishling.register_harness(:bad) do
          private

          def call(run) = run.escalate
        end
      end.to raise_error(Squishling::ConfigurationError, /call must be public/)
    end

    it "rejects a call that doesn't take the run first, or each declared option as a keyword" do
      expect { Squishling.register_harness(:bad) { def call(**); end } }
        .to raise_error(Squishling::ConfigurationError, /call must take the run as its first argument/)
      expect do
        Squishling.register_harness(:bad) do
          option :rounds, :integer
          def call(run); end
        end
      end.to raise_error(Squishling::ConfigurationError, /call doesn't take rounds/)
      expect { Squishling.register_harness(:bad) { def call(run, rounds:); end } }
        .to raise_error(Squishling::ConfigurationError, /call requires undeclared rounds/)
      expect do
        Squishling.register_harness(:bad) do
          option :rounds, :integer
          def call(run, rounds:); end
        end
      end.to raise_error(Squishling::ConfigurationError, /call requires optional rounds \(give it a default\)/)
      expect { Squishling.register_harness(:bad) { def call(run, extra); end } }
        .to raise_error(Squishling::ConfigurationError, /call takes the run, then options as keywords only/)
      expect do
        Squishling.register_harness(:bad) do
          def initialize(mode); end
          def call(run) = run.escalate
        end
      end.to raise_error(Squishling::ConfigurationError, /created without arguments/)
      expect do
        Squishling.register_harness(:bad) do
          option :rounds, :integer
          def call(run, rounds:, **); end
        end
      end.to raise_error(Squishling::ConfigurationError, /call requires optional rounds/)
      expect { Squishling.register_harness(:bad) { def call(run, extra:, **); end } }
        .to raise_error(Squishling::ConfigurationError, /call requires undeclared extra/)
      expect { Squishling.register_harness(:ok) { def call(run, **); end } }.not_to raise_error
    end

    it "still rejects a nil option the type doesn't declare" do
      expect { Squishling::Harness.normalize({ type: :squishsum, judge: nil }, "X") }
        .to raise_error(Squishling::ConfigurationError, /unknown harness option\(s\) judge/)
    end

    it "rejects an option type it doesn't know" do
      expect { Class.new(Squishling::Harness::Base) { option :rounds, :float } }
        .to raise_error(Squishling::ConfigurationError, /type must be one of step, proc, .*or a callable taking/)
      [->(value) { value }, ->(value, label = nil) { [value, label] }, ->(value, label, name, strict:) {},
       Class.new { def call(value) = value }.new].each do |bad|
        expect { Class.new(Squishling::Harness::Base) { option :rounds, bad } }
          .to raise_error(Squishling::ConfigurationError, /or a callable taking \(value, label, name\)/)
      end
      with_parameters = Class.new do
        def parameters = { a: 1 }
        def call(*) = 1
      end.new
      [->(value, label, name) {}, ->(value, *) {}, ->(*) {}, ->(value, label, name = nil) {}, proc { |value| value },
       proc { |value, label| [value, label] }, with_parameters, method(:puts)].each do |ok|
        expect { Class.new(Squishling::Harness::Base) { option :rounds, ok } }.not_to raise_error
      end
    end

    it "doesn't register a harness that fails a check" do
      expect { Squishling.register_harness(:bad, Class.new) }.to raise_error(Squishling::ConfigurationError)

      expect(Squishling.harnesses).not_to include(:bad)
    end

    it "is forgotten by reset_harnesses!, which keeps the built-ins, but not by reset_config!" do
      Squishling.register_harness(:tiebreaker, tiebreaker)

      Squishling.reset_config!
      expect(Squishling.harnesses).to include(:tiebreaker)

      Squishling.reset_harnesses!
      expect(Squishling.harnesses).to eq(%i[escalation squishsum judged_squishsum])
    end

    it "lets one class be registered under two names" do
      Squishling.register_harness(:tiebreaker, tiebreaker)
      Squishling.register_harness(:arbiter, tiebreaker)

      expect(Squishling::Harness.normalize({ type: :arbiter, tiebreaker: "x" }, "X").type).to eq(:arbiter)
      expect(Squishling::Harness.normalize({ type: :tiebreaker, tiebreaker: "x" }, "X").type).to eq(:tiebreaker)
    end

    it "rejects options declared on Harness::Base itself, which every harness inherits" do
      expect { Squishling::Harness::Base.option(:rounds, :integer) }
        .to raise_error(Squishling::ConfigurationError, /not on Base/)
      expect(Squishling::Harness::Base.options).to be_empty
    end

    it "rejects an option named type, which names the harness in a harness Hash" do
      expect { Class.new(Squishling::Harness::Base) { option :type, :symbol } }
        .to raise_error(Squishling::ConfigurationError, /option :type is taken/)
    end

    it "lets exactly one of concurrent registrations of a name win" do
      outcomes = Array.new(8) do
        Thread.new do
          Squishling.register_harness(:tiebreaker, tiebreaker)
          :registered
        rescue Squishling::ConfigurationError
          :rejected
        end
      end.map(&:value)

      expect(outcomes.tally).to eq(registered: 1, rejected: 7)
    end
  end

  describe "declaring a custom harness" do
    before { Squishling.register_harness(:tiebreaker, tiebreaker) }

    it "reads a harness Hash with String keys" do
      harness = Squishling::Harness.normalize({ "type" => "tiebreaker", "tiebreaker" => "claude-opus-5-5" }, "X")

      expect(harness.type).to eq(:tiebreaker)
      expect(harness.options).to include(tiebreaker: include(model: "claude-opus-5-5"))
    end

    it "resolves the type where a built-in type is used" do
      expect { klass.squishling(harness: { type: :tiebreaker, tiebreaker: "claude-opus-5-5" }) }.not_to raise_error
      expect { klass.squish(:triage, harness: { type: "tiebreaker", tiebreaker: "claude-opus-5-5" }) { string :team } }
        .not_to raise_error
      expect { Squishling.configure { |c| c.default_harness = { type: :tiebreaker, tiebreaker: "claude-opus-5-5" } } }
        .not_to raise_error
      expect { klass.squishling_definition(:call).for_call(harness: { type: :tiebreaker, tiebreaker: "x" }) }
        .not_to raise_error
    end

    it "lists the registered types for an unknown one" do
      expect { klass.squishling(harness: :majority) }
        .to raise_error(Squishling::ConfigurationError,
          /unknown harness :majority \(use escalation, squishsum, judged_squishsum, tiebreaker\)/)
    end

    it "keeps the harness it was declared with after reset_harnesses!" do
      klass.squishling(harness: { type: :tiebreaker, tiebreaker: "claude-opus-5-5" })
      Squishling.reset_harnesses!
      stub_llm_chats([high], [high])

      expect(klass.call(text: "x").priority).to eq("high")
    end

    it "checks the options up front, before any request" do
      expect(RubyLLM).not_to receive(:chat)

      expect { klass.squishling(harness: :tiebreaker) }
        .to raise_error(Squishling::ConfigurationError, /harness option\(s\) tiebreaker required/)
      expect { klass.squishling(harness: { type: :tiebreaker }) }
        .to raise_error(Squishling::ConfigurationError, /harness option\(s\) tiebreaker required/)
      expect { klass.squishling(harness: { type: :tiebreaker, tiebreaker: nil }) }
        .to raise_error(Squishling::ConfigurationError, /tiebreaker required/)
      expect { klass.squishling(harness: { type: :tiebreaker, tiebreaker: "x", rounds: 3, depth: 1 }) }
        .to raise_error(Squishling::ConfigurationError, /unknown harness option\(s\) rounds, depth/)
      expect { klass.squishling(harness: { type: :tiebreaker, tiebreaker: "x", compare: :== }) }
        .to raise_error(Squishling::ConfigurationError, /compare: must be a Proc, got Symbol/)
      expect { klass.squishling(harness: { type: :tiebreaker, tiebreaker: 3 }) }
        .to raise_error(Squishling::ConfigurationError, /each step must be a model name or a Hash/)
      expect { klass.squishling(harness: { type: :tiebreaker, tiebreaker: { model: "x", priority: 1 } }) }
        .to raise_error(Squishling::ConfigurationError, /a harness step takes no priority: or rotate:/)
      expect { klass.squishling(harness: { type: :tiebreaker, tiebreaker: { model: "x", rotate: false } }) }
        .to raise_error(Squishling::ConfigurationError, /a harness step takes no priority: or rotate:/)
      expect { klass.squishling(harness: { type: :tiebreaker, tiebreaker: { model: "x", attempts: 0 } }) }
        .to raise_error(Squishling::ConfigurationError, /attempts: must be a positive Integer/)
      expect { klass.squish(:triage, harness: { type: :tiebreaker }) { string :team } }
        .to raise_error(Squishling::ConfigurationError, /^#{klass}: harness option\(s\)|\bsquish\b.*required/)
      expect { klass.squishling_definition(:call).for_call(harness: { type: :tiebreaker }) }
        .to raise_error(Squishling::ConfigurationError, /squish!: harness option\(s\) tiebreaker required/)
      expect { Squishling.configure { |c| c.default_harness = { type: :tiebreaker } } }
        .to raise_error(Squishling::ConfigurationError, /default_harness: harness option\(s\) tiebreaker required/)
    end

    it "checks each option type" do
      checked = Class.new(Squishling::Harness::Base) do
        option :step, :step
        option :judge, Squishling::Harness::JudgedSquishsum.method(:normalize_judge)
        option :callback, :proc
        option :text, :string
        option :mode, :symbol
        option :rounds, :integer
        option :strict, :boolean

        def call(_run, **); end
      end
      Squishling.register_harness(:checked, checked)
      options = { step: "claude-opus-5-5", judge: { model: "jev-latest", type: :judgment },
                  callback: -> {}, text: "t", mode: "fast", rounds: 2, strict: false }

      normalized = Squishling::Harness.normalize({ type: :checked, **options }, "X").options

      expect(normalized).to include(step: include(model: "claude-opus-5-5", attempts: 1), mode: :fast, rounds: 2,
        strict: false, text: "t")
      expect(normalized[:judge]).to include(model: "jev-latest", type: :judgment, min_confidence: 0.8)
      expect(normalized).to be_frozen
      expect(normalized[:step]).to be_frozen
      expect(normalized[:judge]).to be_frozen
      with_params = { type: :checked, step: { model: "x", params: { thinking: { effort: :low } } } }
      expect(Squishling::Harness.normalize(with_params, "X").options[:step][:params][:thinking]).to be_frozen
      {
        judge: [{ model: "x", type: :vote }, /type: must be one of chat, judgment/],
        text: [:t, /text: must be a String, got Symbol/],
        mode: [3, /mode: must be a Symbol, got Integer/],
        rounds: ["2", /rounds: must be an Integer, got String/],
        strict: [nil.to_s, /strict: must be true or false/]
      }.each do |name, (value, message)|
        expect { Squishling::Harness.normalize({ type: :checked, name => value }, "X") }
          .to raise_error(Squishling::ConfigurationError, message)
      end
    end

    it "leaves the objects it was given unfrozen, freezing only its own copies" do
      model = +"claude-opus-5-5"
      stop = ["END"]
      options = Squishling::Harness.normalize(
        { type: :tiebreaker, tiebreaker: { model:, params: { stop: } } }, "X"
      ).options

      expect(options[:tiebreaker][:params][:stop]).to eq(["END"]).and be_frozen
      expect([model, stop]).to all(satisfy { |object| !object.frozen? })

      text = +"Pick one."
      strings = Squishling::Harness::OptionTypes
      expect(strings.check(:string, text, "X", :text)).to be_frozen
      expect(strings.check(->(value, _label, _name) { value }, text, "X", :text)).to be_frozen
      expect(text).not_to be_frozen
    end

    it "takes a callable as an option's type, giving it the value, the declaration site, and the name" do
      seen = nil
      shouted = lambda do |value, label, name|
        seen = [label, name]
        raise Squishling::ConfigurationError, "#{label}: #{name}: must be a word" unless value.is_a?(String)

        value.upcase
      end
      Squishling.register_harness(:shouting) do
        option :word, shouted
        def call(run, **) = run.escalate
      end

      options = Squishling::Harness.normalize({ type: :shouting, word: "hey" }, "X").options

      expect(options).to eq(word: "HEY")
      expect(options[:word]).to be_frozen
      expect(seen).to eq(["X", :word])
      expect { Squishling::Harness.normalize({ type: :shouting, word: 3 }, "X") }
        .to raise_error(Squishling::ConfigurationError, /X: word: must be a word/)
    end

    it "runs validate_options! with the normalized options, to check them against each other" do
      exclusive = Class.new(Squishling::Harness::Base) do
        option :first, :integer
        option :second, :integer

        def self.validate_options!(options, label)
          return unless options.key?(:first) && options.key?(:second)

          raise Squishling::ConfigurationError, "#{label}: give first: or second:, not both"
        end

        def call(_run, **); end
      end
      Squishling.register_harness(:exclusive, exclusive)

      expect(Squishling::Harness.normalize({ type: :exclusive, first: 1 }, "X").options).to eq(first: 1)
      expect { Squishling::Harness.normalize({ type: :exclusive, first: 1, second: 2 }, "X") }
        .to raise_error(Squishling::ConfigurationError, /X: give first: or second:, not both/)
    end

    it "is used when declared on a class, a method, a squish! call, or as the configured default" do
      klass.squishling(harness: { type: :tiebreaker, tiebreaker: "claude-opus-5-5" })
      expect(klass.squishling_definition(:call).harness.type).to eq(:tiebreaker)
      expect(Class.new(klass).squishling_definition(:call).harness.type).to eq(:tiebreaker)

      klass.squish(:call, harness: :squishsum)
      expect(klass.squishling_definition(:call).harness.type).to eq(:squishsum)
      expect(klass.squishling_definition(:call).for_call(harness: { type: :tiebreaker, tiebreaker: "x" }).harness.type)
        .to eq(:tiebreaker)

      other = Class.new do
        include Squishling

        purpose "Triage."
        output_schema { string :priority }
      end
      Squishling.configure { |c| c.default_harness = { type: :tiebreaker, tiebreaker: "claude-opus-5-5" } }
      expect(other.squishling_definition(:call).harness.type).to eq(:tiebreaker)
    end

    it "runs from a squish! call in a method's Ruby implementation" do
      handed = Class.new do
        include Squishling

        purpose "Triage the ticket."
        output_schema { string :priority }
        squishling escalation: ["claude-haiku-4-5", "claude-sonnet-5-5"]

        def call(text:)
          squish!(harness: { type: :tiebreaker, tiebreaker: "claude-opus-5-5" }) if text.empty?
        end
      end
      chats = stub_llm_chats([{ "priority" => "high" }], [{ "priority" => "low" }], [{ "priority" => "low" }])

      result = handed.call(text: "")

      expect(result.priority).to eq("low")
      expect(chats.map(&:model)).to eq(%w[claude-haiku-4-5 claude-sonnet-5-5 claude-opus-5-5])
    end
  end

  describe "running" do
    before do
      Squishling.register_harness(:tiebreaker, tiebreaker)
      klass.squishling(harness: { type: :tiebreaker, tiebreaker: "claude-opus-5-5" })
    end

    it "returns the first sample when the two models agree, without the tiebreaker" do
      chats = stub_llm_chats([high], [high])

      result = klass.call(text: "x")

      expect(result.priority).to eq("high")
      expect(result).to be_squished
      expect(chats.map(&:model)).to eq(%w[claude-haiku-4-5 claude-sonnet-5-5])
    end

    it "asks the tiebreaker when they differ, and returns its typed result" do
      chats = stub_llm_chats([high], [low], [low])

      result = klass.call(text: "x")

      expect(result.priority).to eq("low")
      expect(result).to be_squished
      expect(result.class).to eq(klass.squishling_definition(:call).schema.result_class)
      expect(chats.map(&:model)).to eq(%w[claude-haiku-4-5 claude-sonnet-5-5 claude-opus-5-5])
    end

    it "decides agreement with the harness's own compare:, run against the instance with the inputs" do
      seen = nil
      klass.squishling(harness: { type: :tiebreaker, tiebreaker: "claude-opus-5-5",
                                  compare: lambda { |first, second, **inputs|
                                    seen = [self.class, first.team, second.team, inputs]
                                    first.team == second.team
                                  } })
      chats = stub_llm_chats([high], [low])

      expect(klass.call(text: "x").priority).to eq("high")
      expect(seen).to eq([klass, "api", "api", { text: "x" }])
      expect(chats.size).to eq(2)
    end

    it "sends each sample its own chat with the purpose and the same input" do
      chats = stub_llm_chats([high], [high])

      klass.call(text: "x")

      expect(chats.map(&:instructions).uniq.size).to eq(1)
      expect(chats.first.instructions).to start_with("Triage the ticket.")
      expect(chats.map { |chat| JSON.parse(chat.messages.first) }.uniq).to eq([{ "arguments" => { "text" => "x" } }])
    end

    it "resolves each stage's provider and params the way the escalation does" do
      klass.squishling(params: { temperature: 0.1, top_p: 0.9 })
      klass.squishling(harness: { type: :tiebreaker, compare: ->(*) { false },
                                  tiebreaker: { model: "claude-opus-5-5", provider: :anthropic,
                                                params: { temperature: 0.5 } } })
      chats = stub_llm_chats([high], [low], [low])

      klass.call(text: "x")

      expect(chats.first.generation).to include(temperature: 0.1)
      expect(chats.last.options).to include(provider: :anthropic)
      expect(chats.last.generation).to include(temperature: 0.5, provider_options: { top_p: 0.9 })
    end

    it "retries a sample in its own chat up to its stage's attempts, running squish_validate each time" do
      klass.squishling(escalation: [{ model: "claude-haiku-4-5", attempts: 2 }, "claude-sonnet-5-5"])
      klass.squish_validate { |result, **| "team must be api" unless result.team == "api" }
      chats = stub_llm_chats([{ "priority" => "high", "team" => "web" }, high], [high])

      expect(klass.call(text: "x").priority).to eq("high")
      expect(chats.map { |chat| chat.messages.size }).to eq([2, 1])
      expect(chats.first.messages.last).to include("Your previous response was rejected", "team must be api")
    end

    it "escalates through its stages in order, forwarding a rejected output to the next" do
      Squishling.register_harness(:ladder) do
        def call(run)
          run.escalate("claude-haiku-4-5", { model: "claude-sonnet-5-5", attempts: 2 })
        end
      end
      klass.squishling(harness: :ladder)
      chats = stub_llm_chats(["not json"], [{ "priority" => 1 }, high])

      expect(klass.call(text: "x").priority).to eq("high")
      expect(chats.map(&:model)).to eq(%w[claude-haiku-4-5 claude-sonnet-5-5])
      expect(chats.last.messages.first).to include("A previous attempt at this request returned:", "not json")
    end

    it "runs the escalation's own steps when escalate takes no stage" do
      Squishling.register_harness(:plain) { def call(run) = run.escalate }
      klass.squishling(harness: :plain)
      chats = stub_llm_chats(["not json"], [high])

      expect(klass.call(text: "x").priority).to eq("high")
      expect(chats.map(&:model)).to eq(%w[claude-haiku-4-5 claude-sonnet-5-5])
    end

    it "exposes the receiver, the inputs, the label, and the stages" do
      seen = nil
      Squishling.register_harness(:inspect) do
        define_method(:call) do |run|
          seen = [run.receiver.class, run.inputs, run.label, run.stages.map { |stage| stage.map(&:model) },
                  run.steps.size, run.steps.frozen?]
          run.escalate
        end
      end
      klass.squishling(escalation: [{ model: "claude-haiku-4-5", attempts: 2 }, "claude-sonnet-5-5"],
        harness: :inspect)
      stub_llm(high)

      klass.call(text: "x")

      expect(seen).to eq([klass, { text: "x" }, "#{klass}#call",
                          [%w[claude-haiku-4-5 claude-haiku-4-5], %w[claude-sonnet-5-5]], 3, true])
    end

    it "judges two samples through run.judge, on the escalation's next stage by default" do
      Squishling.register_harness(:arbiter) do
        option :instructions, Squishling::Harness::JudgedSquishsum.method(:normalize_instructions)

        def call(run, instructions: nil)
          judge = run.judge(instructions:)
          stage = run.stages.first
          first, second = run.samples([stage, stage])
          return first if run.agree?(first, second)

          verdict = judge.verdict(first, second)
          verdict.choice == :b ? second : first
        end
      end
      klass.squishling(harness: { type: :arbiter, instructions: "Prefer the calmer ticket." })
      chats = stub_llm_chats([high], [low], [{ "verdict" => "b", "reason" => "routine" }])

      expect(klass.call(text: "x").priority).to eq("low")
      expect(chats.last.model).to eq("claude-sonnet-5-5")
      expect(chats.last.instructions).to start_with("Prefer the calmer ticket.")
    end

    it "judges with a given judge, a System One judgment model included" do
      Squishling.register_harness(:arbiter) do
        option :judge, Squishling::Harness::JudgedSquishsum.method(:normalize_judge), required: true

        def call(run, judge:)
          judge = run.judge(judge:)
          stage = run.stages.first
          first, second = run.samples([stage, stage])
          verdict = judge.verdict(first, second)
          [verdict.choice, verdict.reason, judge.step.model, first.priority, second.priority]
          verdict.choice == :a ? first : second
        end
      end
      klass.squishling(harness: { type: :arbiter, judge: { model: "jev-latest", type: :judgment } })
      stub_llm_chats([high], [low])
      calls = stub_judgment({ choice: :b, probabilities: { a: 0.1, b: 0.85, neither: 0.05 } })

      expect(klass.call(text: "x").priority).to eq("low")
      expect(calls.first[:options]).to include(model: "jev-latest")
    end

    it "fails before any request when the judge it needs isn't there" do
      Squishling.register_harness(:arbiter) do
        def call(run)
          run.judge
          run.escalate
        end
      end
      klass.squishling(escalation: ["claude-haiku-4-5"], harness: :arbiter)
      expect(RubyLLM).not_to receive(:chat)

      expect { klass.call(text: "x") }
        .to raise_error(Squishling::ConfigurationError, /the arbiter harness needs a judge: or a second escalation/)
    end

    it "logs through run.log with the label" do
      io = StringIO.new
      Squishling.configure { |c| c.logger = Logger.new(io) }
      Squishling.register_harness(:noisy) do
        def call(run)
          run.log("starting")
          run.escalate
        end
      end
      klass.squishling(harness: :noisy)
      stub_llm(high)

      klass.call(text: "x")

      expect(io.string).to include("WARN -- : [Squishling] #{klass}#call starting")
    end
  end

  describe "squawk" do
    let(:calls) { [] }

    before do
      Squishling.register_harness(:tiebreaker, tiebreaker)
      klass.squishling(harness: { type: :tiebreaker, tiebreaker: "claude-opus-5-5" },
        squawk: ->(output:, metadata:, error:) { calls << { output:, metadata:, error: } })
    end

    it "reports every attempt, each sample by name and role, with its usage" do
      tokens = RubyLLM::Tokens.new(input: 10, output: 5)
      response = ->(content, model) { FakeChat::Response.new(content, model, tokens) }
      stub_llm_chats([response.call(high, "claude-haiku-4-5")], [response.call(low, "claude-sonnet-5-5")],
        [response.call(low, "claude-opus-5-5")])

      klass.call(text: "x")

      expect(calls.map { |call| call[:metadata].values_at(:role, :sample, :model, :attempt, :attempts, :final) })
        .to eq([[:sample, "a", "claude-haiku-4-5", 1, 1, true],
                [:sample, "b", "claude-sonnet-5-5", 1, 1, true],
                [nil, nil, "claude-opus-5-5", 1, 1, true]])
      expect(calls.map { |call| call[:output] }).to eq([high, low, low])
      expect(calls.map { |call| call[:metadata][:usage] }).to all(include(input_tokens: 10, output_tokens: 5))
      expect(calls.map { |call| call[:error] }).to all(be_nil)
    end

    it "reports a rejected sample attempt with the error, and the retry that follows" do
      klass.squishling(escalation: [{ model: "claude-haiku-4-5", attempts: 2 }, "claude-sonnet-5-5"])
      stub_llm_chats([{ "priority" => 1 }, high], [high])

      klass.call(text: "x")

      sample_a = calls.select { |call| call[:metadata][:sample] == "a" }
      expect(sample_a.map { |call| call[:metadata][:attempt] }).to eq([1, 2])
      expect(sample_a.first[:error]).to be_a(Squishling::InvalidOutputError)
      expect(sample_a.last[:error]).to be_nil
    end

    it "marks a judge's attempts as the judge role" do
      Squishling.register_harness(:arbiter) do
        def call(run)
          stage = run.stages.first
          first, second = run.samples([stage, stage])
          run.judge.verdict(first, second).choice == :a ? first : second
        end
      end
      klass.squishling(harness: :arbiter)
      stub_llm_chats([high], [low], [{ "verdict" => "a", "reason" => "urgent" }])

      klass.call(text: "x")

      expect(calls.map { |call| call[:metadata].values_at(:role, :sample) })
        .to eq([[:sample, "a"], [:sample, "b"], [:judge, nil]])
    end

    it "leaves the built-in harnesses' escalation attempts without a role" do
      klass.squishling(harness: :escalation)
      stub_llm(high)

      klass.call(text: "x")

      expect(calls.map { |call| call[:metadata].values_at(:role, :sample) }).to eq([[nil, nil]])
    end
  end

  describe "failing" do
    # Needs every sample to agree, as :squishsum does, but over three of them.
    let(:unanimous) do
      Class.new(Squishling::Harness::Base) do
        def call(run)
          stage = run.stages.first
          results = run.samples([stage, stage, stage])
          return results.first if results.map(&:to_h).uniq.one?

          raise Squishling::DisagreementError.new(candidates: results, models: [stage.first.model] * 3)
        end
      end
    end

    def register_unanimous
      Squishling.register_harness(:unanimous, unanimous)
      klass.squishling(harness: :unanimous)
    end

    it "hands a DisagreementError the harness raises to squish_fallback, like the built-ins" do
      register_unanimous
      klass.squish_fallback { |error, **| error.candidates.last }
      stub_llm_chats([high], [low], [low])

      result = klass.call(text: "x")

      expect(result.priority).to eq("low")
      expect(result).to be_squished
    end

    it "raises the DisagreementError without a fallback, with every candidate typed" do
      register_unanimous
      stub_llm_chats([high], [low], [low])

      expect { klass.call(text: "x") }.to raise_error(Squishling::DisagreementError) do |e|
        expect(e).to be_a(Squishling::InvalidOutputError)
        expect(e.candidates.map(&:priority)).to eq(%w[high low low])
        expect(e.models).to eq(%w[claude-haiku-4-5] * 3)
      end
    end

    it "raises InvalidOutputError from a sample still invalid after its attempts, to the fallback too" do
      register_unanimous
      klass.squishling(escalation: [{ model: "claude-haiku-4-5", attempts: 2 }])
      klass.squish_fallback { |error, **| { priority: "fallback-#{error.attempts}", team: "ops" } }
      stub_llm_chats([high], [{ "priority" => 1 }, { "priority" => 2 }], [high])

      result = klass.call(text: "x")

      expect(result.priority).to eq("fallback-2")
      expect(result).not_to be_squished
    end

    it "raises LLMError from a failed request on the last attempt, to the fallback too" do
      register_unanimous
      klass.squish_fallback { |error, **| { priority: error.class.name, team: "ops" } }
      stub_llm_chats([high], [Faraday::TimeoutError.new("slow")], [high])

      expect(klass.call(text: "x").priority).to eq("Squishling::LLMError")
    end

    it "raises an InvalidOutputError of its own to the fallback" do
      Squishling.register_harness(:picky) do
        def call(_run) = raise(Squishling::InvalidOutputError.new(errors: ["no"], source: "Harness"))
      end
      klass.squishling(harness: :picky)
      klass.squish_fallback { |error, **| { priority: error.errors.first, team: "ops" } }
      expect(RubyLLM).not_to receive(:chat)

      expect(klass.call(text: "x").priority).to eq("no")
    end

    it "never sends a ConfigurationError to the fallback" do
      Squishling.register_harness(:broken) do
        def call(_run) = raise(Squishling::ConfigurationError, "broken harness")
      end
      klass.squishling(harness: :broken)
      klass.squish_fallback { |_error, **| { priority: "fallback", team: "ops" } }

      expect { klass.call(text: "x") }.to raise_error(Squishling::ConfigurationError, "broken harness")
    end

    it "propagates the developer's own exceptions unwrapped, never to the fallback" do
      Squishling.register_harness(:bug) { def call(_run) = raise(KeyError, "my bug") }
      klass.squishling(harness: :bug)
      klass.squish_fallback { |_error, **| { priority: "fallback", team: "ops" } }

      expect { klass.call(text: "x") }.to raise_error(KeyError, "my bug")
    end

    it "lets a compare: exception through unwrapped" do
      Squishling.register_harness(:tiebreaker, tiebreaker)
      klass.squishling(harness: { type: :tiebreaker, tiebreaker: "x", compare: ->(*) { raise IndexError, "mine" } })
      stub_llm_chats([high], [low])

      expect { klass.call(text: "x") }.to raise_error(IndexError, "mine")
    end

    it "raises ConfigurationError when the harness returns something its run didn't produce" do
      klass.squish_fallback { |_error, **| { priority: "fallback", team: "ops" } }
      schema = klass.squishling_definition(:call).schema
      {
        hash: -> { { priority: "high", team: "api" } },
        nil: -> {},
        hand_built: -> { schema.result_class.new(squishling_squished: true, priority: "bogus", team: "x") },
        rebuilt: ->(first) { first.with(priority: "bogus") },
        other_class: -> { Class.new { include Squishling }.new }
      }.each_value do |build|
        Squishling.reset_harnesses!
        Squishling.register_harness(:sneaky) do
          define_method(:call) do |run|
            first = run.escalate
            build.arity.zero? ? build.call : build.call(first)
          end
        end
        klass.squishling(harness: :sneaky)
        stub_llm(high)

        expect { klass.call(text: "x") }
          .to raise_error(Squishling::ConfigurationError, /the sneaky harness must return a result from its run/)
      end
    end

    it "accepts a result a primitive produced, whichever sample or attempt it came from" do
      Squishling.register_harness(:second) { def call(run) = run.samples([run.stages.first] * 2).last }
      klass.squishling(harness: :second)
      stub_llm_chats([high], [low])

      expect(klass.call(text: "x").priority).to eq("low")
    end

    it "only accepts the results its run produced for a schema without a result class too" do
      plain = Class.new do
        include Squishling

        squishling model: "claude-haiku-4-5"
        purpose "Count the words."
        output_schema({ "type" => "object", "additionalProperties" => { "type" => "integer" } })
      end
      Squishling.register_harness(:fabricating) { def call(run) = run.escalate && { "words" => 5 } }
      Squishling.register_harness(:honest) { def call(run) = run.escalate }
      stub_llm({ "words" => 3 }, { "words" => 3 })

      plain.squishling(harness: :honest)
      expect(plain.call(text: "a b c")).to eq("words" => 3)

      plain.squishling(harness: :fabricating)
      expect { plain.call(text: "a b c") }.to raise_error(Squishling::ConfigurationError, /must return a result/)
    end
  end

  describe "the run's primitives" do
    def with_harness(&body)
      Squishling.register_harness(:probe) { define_method(:call, &body) }
      klass.squishling(harness: :probe)
    end

    it "validates a step Hash wherever it comes from, and leaves a stage the caller owns unfrozen" do
      with_harness { |run| run.escalate({ model: "claude-haiku-4-5", priority: 1 }) }
      expect { klass.call(text: "x") }
        .to raise_error(Squishling::ConfigurationError, /a harness step takes no priority: or rotate:/)

      Squishling.reset_harnesses!
      mine = []
      with_harness do |run|
        mine.replace(run.steps.first(1))
        run.escalate(mine)
      end
      stub_llm(high)

      klass.call(text: "x")
      expect(mine).not_to be_frozen
    end

    it "applies the params checks to a step that was changed by hand" do
      with_harness { |run| run.escalate(run.steps.first.with(params: { tools: [] })) }

      expect { klass.call(text: "x") }
        .to raise_error(Squishling::ConfigurationError, /tools can't be set through params/)
    end

    it "rejects samples given something other than an Array of stages" do
      ["claude-haiku-4-5", nil, { model: "x" }].each do |bad|
        Squishling.reset_harnesses!
        with_harness { |run| run.samples(bad) }

        expect { klass.call(text: "x") }
          .to raise_error(Squishling::ConfigurationError, /samples takes an Array of stages/)
      end
    end

    it "rejects no stages, and more samples than names" do
      with_harness { |run| run.samples([]) }
      expect { klass.call(text: "x") }
        .to raise_error(Squishling::ConfigurationError, /samples needs at least one stage/)

      Squishling.reset_harnesses!
      with_harness { |run| run.samples([run.stages.first] * 27) }
      expect { klass.call(text: "x") }.to raise_error(Squishling::ConfigurationError, /samples takes at most 26/)
    end

    it "rejects a sample stage that mixes models, which would retry on the wrong one" do
      with_harness { |run| run.samples([run.steps]) }

      expect { klass.call(text: "x") }
        .to raise_error(Squishling::ConfigurationError, /a sample is asked on one model.*claude-haiku-4-5, claude-sonn/)
    end

    it "lets escalate take a mixed Array of steps, such as the escalation itself" do
      with_harness { |run| run.escalate(run.steps) }
      chats = stub_llm_chats(["not json"], [high])

      expect(klass.call(text: "x").priority).to eq("high")
      expect(chats.map(&:model)).to eq(%w[claude-haiku-4-5 claude-sonnet-5-5])
    end

    it "rejects a stage that isn't the steps of one model" do
      [[], %w[claude-haiku-4-5], [:haiku], 3].each do |bad|
        Squishling.reset_harnesses!
        with_harness { |run| run.stage(bad) }

        expect { klass.call(text: "x") }
          .to raise_error(Squishling::ConfigurationError, /a stage is the steps of one model|each step must be a model/)
      end
    end

    it "takes a stage, a step, or a declaration, and resolves each the same way" do
      seen = nil
      with_harness do |run|
        seen = [run.stage(run.steps.first), run.stage("claude-opus-5-5"), run.stage({ model: "x", attempts: 2 }),
                run.stage(run.stage("claude-opus-5-5").first.then { |step| { model: step.model } })]
        run.escalate
      end
      stub_llm(high)

      klass.call(text: "x")

      expect(seen.map { |stage| stage.map(&:model) })
        .to eq([%w[claude-haiku-4-5], %w[claude-opus-5-5], %w[x x], %w[claude-opus-5-5]])
      expect(seen).to all(be_frozen)
    end

    it "retries samples of different stage sizes on their own, without disturbing a finished one" do
      klass.squishling(escalation: ["claude-haiku-4-5", { model: "claude-sonnet-5-5", attempts: 2 }])
      results = nil
      with_harness do |run|
        results = run.samples(run.stages.first(2))
        results.first
      end
      chats = stub_llm_chats([high], [{ "priority" => 1 }, low])

      klass.call(text: "x")

      expect(results.map(&:priority)).to eq(%w[high low])
      expect(chats.map { |chat| chat.messages.size }).to eq([1, 2])
      expect(chats.map(&:model)).to eq(%w[claude-haiku-4-5 claude-sonnet-5-5])
    end

    it "starts a step from the input alone when it sets forward_rejected: false" do
      with_harness { |run| run.escalate("claude-haiku-4-5", { model: "claude-sonnet-5-5", forward_rejected: false }) }
      chats = stub_llm_chats(["not json"], [high])

      klass.call(text: "x")

      expect(chats.last.messages.first).not_to include("previous attempt")
    end

    it "evaluates judge instructions given as a Proc against the instance, and rejects a blank one" do
      klass.class_eval { define_method(:tone) { "Prefer calm." } }
      with_harness do |run|
        judge = run.judge(instructions: -> { tone })
        first, second = run.samples([run.stages.first] * 2)
        judge.verdict(first, second).choice == :a ? first : second
      end
      chats = stub_llm_chats([high], [low], [{ "verdict" => "a", "reason" => "ok" }])

      klass.call(text: "x")
      expect(chats.last.instructions).to start_with("Prefer calm.")

      Squishling.reset_harnesses!
      with_harness do |run|
        first, second = run.samples([run.stages.first] * 2)
        run.judge(instructions: -> { " " }).verdict(first, second)
      end
      stub_llm_chats([high], [low])
      expect { klass.call(text: "x") }
        .to raise_error(Squishling::ConfigurationError, /judge_instructions proc must return a non-blank String/)
    end

    it "lets a step carry extra keys for its caller, and still rejects any others" do
      step = Squishling::ModelPath.normalize_step({ "model" => "x", "tag" => 1 }, "X", extras: %i[tag])

      expect(step).to eq(model: "x", provider: nil, params: nil, attempts: 1, forward_rejected: true, tag: 1)
      expect { Squishling::ModelPath.normalize_step({ model: "x", other: 1 }, "X", extras: %i[tag]) }
        .to raise_error(Squishling::ConfigurationError, /unknown step option\(s\) other/)
    end

    it "takes a judge as a step with its own keys, and checks them when the judge is made" do
      [
        [{ model: "x", type: :vote }, /judge type: must be one of chat, judgment, got :vote/],
        [{ model: "x", type: 5 }, /judge type: must be one of chat, judgment, got 5/],
        [{ model: "x", type: false }, /judge type: must be one of chat, judgment, got false/],
        [{ model: "x", type: :judgment, min_confidence: 2 }, /judge min_confidence: must be a number from 0 to 1/],
        [{ model: "x", bogus: 1 }, /unknown step option\(s\) bogus/],
        [{ model: "x", priority: 1 }, /a judge is one step, so it takes no priority: or rotate:/],
        [{ model: "x", rotate: false }, /a judge is one step, so it takes no priority: or rotate:/],
        [{ model: "x", min_confidence: 0.5 }, /min_confidence: only applies to type: :judgment judges/],
        [false, /each step must be a model name or a Hash/]
      ].each do |declaration, message|
        Squishling.reset_harnesses!
        with_harness { |run| run.judge(judge: declaration) }

        expect { klass.call(text: "x") }.to raise_error(Squishling::ConfigurationError, message)
      end

      Squishling.reset_harnesses!
      with_harness { |run| run.judge(instructions: " ") }
      expect { klass.call(text: "x") }
        .to raise_error(Squishling::ConfigurationError, /judge instructions must be a non-blank String or a Proc/)
    end

    it "runs a System One judgment step given straight to run.judge, with the default min_confidence" do
      with_harness do |run|
        first, second = run.samples([run.stages.first] * 2)
        run.judge(judge: { model: "jev-latest", type: :judgment }).verdict(first, second).choice == :b ? second : first
      end
      stub_llm_chats([high], [low])
      stub_judgment({ choice: :b, probabilities: { a: 0.1, b: 0.85, neither: 0.05 } })

      expect(klass.call(text: "x").priority).to eq("low")
    end

    it "refuses a judge's verdict asked for from another thread" do
      with_harness do |run|
        judge = run.judge
        first, second = run.samples([run.stages.first] * 2)
        Thread.new do
          Thread.current.report_on_exception = false
          judge.verdict(first, second)
        end.value
      end
      chats = stub_llm_chats([high], [low])

      expect { klass.call(text: "x") }.to raise_error(Squishling::ConfigurationError, /from the thread it runs on/)
      expect(chats.size).to eq(2)
    end
  end

  describe "threads and fibers" do
    before { Squishling.register_harness(:tiebreaker, tiebreaker) }

    # A chat that answers every request with the call's own text as the priority.
    def stub_echo_chat
      echo = Class.new(FakeChat) do
        def ask(message)
          @messages << message
          FakeChat::Response.new({ "priority" => JSON.parse(message).dig("arguments", "text"), "team" => "api" })
        end
      end
      allow(RubyLLM).to receive(:chat) { |model: nil, **options| echo.new(model:, responses: [], **options) }
    end

    it "sends only the samples' requests from worker threads, keeping the harness and every callback on the caller's" do
      threads = Queue.new
      requested = Queue.new
      klass.squishling(harness: { type: :tiebreaker, tiebreaker: "claude-opus-5-5",
                                  compare: lambda { |first, second, **|
                                    threads << [:compare, Thread.current]
                                    first.team == second.team
                                  } })
      klass.squish_validate do |_result, **|
        threads << [:validate, Thread.current]
        nil
      end
      Squishling.register_harness(:watching) do
        define_method(:call) do |run|
          threads << [:harness, Thread.current]
          stage = run.stages.first
          first, second = run.samples([stage, stage])
          run.agree?(first, second) ? first : second
        end
      end
      klass.squishling(harness: :watching)
      stub_llm_chats([high], [high], on_ask: ->(_chat) { requested << Thread.current })

      klass.call(text: "x")

      callbacks = Array.new(threads.size) { threads.pop }
      expect(callbacks.map(&:last).uniq).to eq([Thread.current])
      expect(callbacks.map(&:first)).to include(:harness, :validate)
      expect(Array.new(2) { requested.pop }).to all(satisfy { |thread| thread != Thread.current })
    end

    it "carries the fiber-local instrumentation workflow to the request threads" do
      klass.squishling(harness: { type: :tiebreaker, tiebreaker: "claude-opus-5-5" })
      seen = Queue.new
      stub_llm_chats([high], [high], on_ask: lambda { |_chat|
        seen << RubyLLM::Support::Instrumentation.current_workflow
      })

      RubyLLM::Support::Instrumentation.with_workflow({ name: "triage" }) { klass.call(text: "x") }

      expect([seen.pop, seen.pop]).to eq([{ name: "triage" }] * 2)
    end

    it "has no routing frames on the request threads, which only ask" do
      frames = Queue.new
      klass.squishling(harness: { type: :tiebreaker, tiebreaker: "claude-opus-5-5" })
      stub_llm_chats([high], [high], on_ask: ->(_chat) { frames << Thread.current[Squishling::Router::FRAMES_KEY] })

      klass.call(text: "x")

      expect([frames.pop, frames.pop]).to eq([nil, nil])
      expect(Thread.current[Squishling::Router::FRAMES_KEY]).to be_empty
    end

    it "keeps concurrent calls apart, each with its own run and results" do
      stub_echo_chat
      klass.squishling(harness: { type: :tiebreaker, tiebreaker: "claude-opus-5-5" })

      results = Array.new(8) { |index| Thread.new { klass.call(text: "ticket-#{index}").priority } }.map(&:value)

      expect(results).to eq(Array.new(8) { |index| "ticket-#{index}" })
    end

    it "keeps calls in separate fibers apart" do
      stub_echo_chat
      klass.squishling(harness: { type: :tiebreaker, tiebreaker: "claude-opus-5-5" })

      fibers = Array.new(4) { |index| Fiber.new { klass.call(text: "ticket-#{index}").priority } }

      expect(fibers.map(&:resume)).to eq(Array.new(4) { |index| "ticket-#{index}" })
    end

    it "refuses a primitive called from another thread" do
      Squishling.register_harness(:threaded) do
        def call(run)
          Thread.new do
            Thread.current.report_on_exception = false
            run.escalate
          end.value
        end
      end
      klass.squishling(harness: :threaded)
      expect(RubyLLM).not_to receive(:chat)

      expect { klass.call(text: "x") }
        .to raise_error(Squishling::ConfigurationError, /from the thread it runs on/)
    end

    it "stops the requests still running when the caller is interrupted" do
      started = Queue.new
      klass.squishling(harness: { type: :tiebreaker, tiebreaker: "claude-opus-5-5" })
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
  end
end
