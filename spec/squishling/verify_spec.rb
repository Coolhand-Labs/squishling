# frozen_string_literal: true

require "spec_helper"

RSpec.describe Squishling, ".verify" do
  before do
    Squishling::ClassRegistry.reset!
    Squishling.config.adapter = FakeAdapter.new
  end

  def valid_class(&extra)
    squishling_class do
      squishling model: "claude-haiku-4-5", purpose: "Triage."
      squish :triage do
        string :team
      end
      class_eval(&extra) if extra
    end
  end

  def messages(*classes)
    Squishling.verify(*classes).problems.map(&:to_s)
  end

  it "finds nothing wrong with a sound class" do
    report = Squishling.verify(valid_class)

    expect(report).to be_ok
    expect(report.to_s).to eq("Squishling: no problems found")
  end

  it "makes no provider request, even for a class with a judgment judge or with problems" do
    adapter = Squishling.config.adapter
    expect(adapter).not_to receive(:complete)
    expect(adapter).not_to receive(:judge)
    judged = squishling_class do
      squishling model: "claude-haiku-4-5", purpose: "Triage.",
        harness: { type: :judged_squishsum, judge: { model: "judge", type: :judgment } }
      squish :triage do
        string :team
      end
    end
    broken = squishling_class { squish :bad }

    expect(Squishling.verify(judged, broken).problems).not_to be_empty
  end

  it "checks every registered class when none are given" do
    valid_class
    squishling_class { squish :bad }

    expect(Squishling.verify.size).to eq(2)
  end

  it "raises a ConfigurationError for something that isn't a squishling class" do
    expect { Squishling.verify(String) }.to raise_error(Squishling::ConfigurationError, /String doesn't include/)
    expect { Squishling.verify(nil) }.to raise_error(Squishling::ConfigurationError, /nil doesn't include/)
  end

  it "accepts the classes as an Array" do
    expect(Squishling.verify([valid_class, valid_class])).to be_ok
  end

  it "ignores the default call method on a class that doesn't use it" do
    klass = squishling_class { squish(:other, purpose: "p") { string :a } }

    expect(Squishling.verify(klass)).to be_ok
  end

  describe "the output schema" do
    it "reports a squished method with no schema or purpose" do
      klass = squishling_class do
        squish :triage
      end

      expect(messages(klass)).to contain_exactly(/has no output_schema/, /has no purpose/)
    end

    it "reports a schema that isn't a Schematist schema" do
      klass = squishling_class { squishling purpose: "p", output_schema: String }

      expect(messages(klass)).to contain_exactly(/String is not a Schematist::Schema/)
    end

    it "reports a non-strict schema" do
      schema = { type: "object", properties: { a: { type: "string" } }, required: ["a"], strict: false }
      klass = squishling_class { squishling purpose: "p", output_schema: schema }

      expect(messages(klass)).to contain_exactly(/only supports strict output schemas/)
    end

    it "reports a property name that can't be a result member" do
      schema = { type: "object", properties: { "a=": { type: "string" } }, required: ["a="],
                 additionalProperties: false }
      klass = squishling_class { squishling purpose: "p", output_schema: schema }

      expect(messages(klass)).to contain_exactly(/invalid data member: a=/)
    end

    it "reports an object schema that lacks type: object, without a request" do
      adapter = FakeAdapter.new
      Squishling.config.adapter = adapter
      schema = { type: "object", properties: { n: { properties: { a: { type: "string" } }, required: ["a"] } },
                 required: ["n"], additionalProperties: false }
      klass = squishling_class { squishling purpose: "p", output_schema: schema }

      expect(messages(klass)).to contain_exactly(/`type` isn't "object"/)
      expect(adapter.chats).to be_empty
    end

    it "reports a schema that isn't valid JSON Schema" do
      klass = squishling_class { squishling purpose: "p", output_schema: { type: "objct" } }

      expect(messages(klass)).not_to be_empty
    end

    it "reports a remote $ref, which would otherwise raise on the first response" do
      schema = { type: "object", properties: { a: { "$ref": "https://example.com/a.json" } }, required: ["a"],
                 additionalProperties: false }
      klass = squishling_class { squishling purpose: "p", output_schema: schema }

      expect(messages(klass)).to contain_exactly(%r{\$ref that can't be resolved.*example\.com/a\.json})
    end

    it "accepts a $ref to a local $defs entry" do
      schema = { type: "object", properties: { a: { "$ref": "#/$defs/tag" } }, required: ["a"],
                 additionalProperties: false, "$defs": { tag: { type: "string" } } }
      klass = squishling_class { squishling purpose: "p", output_schema: schema }

      expect(Squishling.verify(klass)).to be_ok
    end

    it "accepts a purpose given as a Proc" do
      klass = squishling_class do
        squishling purpose: -> { "dynamic" }
        squish(:triage) { string :team }
      end

      expect(Squishling.verify(klass)).to be_ok
    end
  end

  describe "include_when:" do
    it "reports a required keyword that isn't an input of the method" do
      klass = valid_class do
        squish :route, escalation: [{ model: "a", include_when: ->(tier:) { tier } }, "b"],
          purpose: "p" do
          string :team
        end

        def route(ticket); end
      end

      expect(messages(klass)).to include(
        a_string_matching(/#route: escalation step "a" include_when: requires tier:, which is not an input/)
      )
    end

    it "reports inputs a lambda doesn't accept" do
      klass = valid_class do
        squish :route, escalation: [{ model: "a", include_when: ->(ticket:) { ticket } }, "b"], purpose: "p" do
          string :team
        end

        def route(ticket, tier: 1); end
      end

      expect(messages(klass).join).to include("include_when: doesn't accept tier:")
    end

    it "accepts a lambda that takes the inputs, or ** for any" do
      klass = valid_class do
        squish :route, escalation: [{ model: "a", include_when: ->(ticket:, **) { ticket } },
                                    { model: "b", include_when: ->(**) { true } }], purpose: "p" do
          string :team
        end

        def route(ticket, tier: 1); end
      end

      expect(Squishling.verify(klass)).to be_ok
    end

    it "can't know the inputs of a method that takes **, or has no implementation" do
      klass = valid_class do
        squish :a, :b, escalation: [{ model: "a", include_when: ->(whatever:) { whatever } }], purpose: "p" do
          string :team
        end

        def a(**options); end
      end

      expect(Squishling.verify(klass)).to be_ok
    end

    it "skips a proc that takes no keywords, which receives them as a Hash" do
      klass = valid_class do
        squish :route, escalation: [{ model: "a", include_when: proc { |inputs| inputs } }, "b"], purpose: "p" do
          string :team
        end

        def route(ticket); end
      end

      expect(Squishling.verify(klass)).to be_ok
    end
  end

  describe "positional lambdas" do
    it "reports a lambda needing a positional argument when it is called with keywords only" do
      klass = valid_class do
        squish :route, escalation: [{ model: "a", include_when: ->(ticket, tier:) { ticket && tier } }, "b"],
          purpose: "p" do
          string :team
        end

        def route(tier: 1); end
      end

      expect(messages(klass).join).to include("takes 1 positional argument(s)")
    end

    it "accepts a lambda that takes the inputs as one Hash" do
      klass = valid_class do
        squish :route, escalation: [{ model: "a", include_when: ->(inputs) { inputs } }, "b"], purpose: "p" do
          string :team
        end

        def route(ticket); end
      end

      expect(Squishling.verify(klass)).to be_ok
    end
  end

  describe "when:" do
    it "reports a predicate that isn't a Proc instead of failing" do
      klass = valid_class { squish :go, when: :foo, purpose: "p" }

      expect(messages(klass).join).to include("squish_when must be a Proc")
    end
  end

  describe "squish_when" do
    it "reports a predicate that requires an unknown keyword" do
      klass = valid_class do
        squish_when { |level:, **| level }

        def triage(ticket); end
      end

      expect(messages(klass).join).to include("squish_when requires level:")
    end

    it "accepts a predicate that takes the inputs" do
      klass = valid_class do
        squish_when { |ticket:| ticket }

        def triage(ticket); end
      end

      expect(Squishling.verify(klass)).to be_ok
    end
  end

  describe "a rest parameter" do
    it "is an input named after it" do
      klass = valid_class do
        squish_when { |args:| args }

        def triage(*args); end
      end

      expect(Squishling.verify(klass)).to be_ok
    end
  end

  describe "the harness" do
    it "reports a harness that was unregistered after the class declared it" do
      Squishling.register_harness(:temporary) { def call(run) = run.escalate }
      klass = valid_class { squishling harness: :temporary }
      Squishling.reset_harnesses!

      expect(messages(klass).join).to include("harness :temporary was unregistered or replaced")
    end

    it "reports a judgment judge on an adapter without judgments" do
      Squishling.config.adapter.judgments_supported = false
      klass = valid_class do
        squishling harness: { type: :judged_squishsum, judge: { model: "judge", type: :judgment } }
      end

      expect(messages(klass).join).to include("judge needs an adapter that supports judgments")
    end

    it "accepts a judgment judge on an adapter that supports them" do
      klass = valid_class do
        squishling harness: { type: :judged_squishsum, judge: { model: "judge", type: :judgment } }
      end

      expect(Squishling.verify(klass)).to be_ok
    end
  end

  describe "the adapter" do
    it "reports when none can be resolved" do
      Squishling.config.adapter = nil
      allow(Squishling::Adapter).to receive(:detect).and_raise(Squishling::ConfigurationError,
        "No adapter is configured")

      expect(messages(valid_class)).to contain_exactly("adapter: No adapter is configured")
    end
  end

  describe "inheritance" do
    it "checks an inherited method against the subclass's own settings" do
      parent = valid_class
      child = Class.new(parent) { squishling output_schema: { type: "objct" } }

      expect(Squishling.verify(parent)).to be_ok
      expect(messages(child)).not_to be_empty
    end
  end

  describe "the report" do
    it "lists every problem, not just the first" do
      klass = squishling_class do
        squish :one
        squish :two, purpose: "p"
      end

      report = Squishling.verify(klass)

      expect(report.size).to eq(3)
      expect(report.to_s).to start_with("Squishling found 3 problems:\n")
      expect(report.to_s.lines.size).to eq(4)
    end

    it "says problem for a single one" do
      klass = squishling_class { squish :one, purpose: "p" }

      expect(Squishling.verify(klass).to_s).to start_with("Squishling found 1 problem:")
    end
  end

  describe "verify!" do
    it "returns the report when sound" do
      expect(Squishling.verify!(valid_class)).to be_ok
    end

    it "raises a ConfigurationError naming every problem" do
      klass = squishling_class { squish :one }

      expect { Squishling.verify!(klass) }.to raise_error(Squishling::VerificationError) { |error|
        expect(error).to be_a(Squishling::ConfigurationError)
        expect(error.problems.size).to eq(2)
        expect(error.report.size).to eq(2)
        expect(error.message).to include("no output_schema", "no purpose")
      }
    end
  end
end
