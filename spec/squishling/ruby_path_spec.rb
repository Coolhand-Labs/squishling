# frozen_string_literal: true

RSpec.describe Squishling::RubyPath do
  # A parser whose Ruby returns the record's first field, or a hash the schema rejects. The body can add
  # declarations and redefine #call.
  def parser(&)
    Class.new do
      include Squishling

      purpose "Parse the record."
      output_schema { string :name }

      def call(record:)
        record.include?(",") ? { name: record.split(",").first } : { nope: record }
      end

      class_eval(&) if block_given?
    end
  end

  def context_of(chat) = JSON.parse(chat.messages.first)["context"]

  describe "by default" do
    it "keeps a valid Ruby return in Ruby, without a call" do
      chats = stub_llm

      result = parser.call(record: "Ada,1815")

      expect(result.name).to eq("Ada")
      expect(result.squished?).to be(false)
      expect(chats).to be_empty
    end

    it "raises when the schema rejects the Ruby return, as it always has" do
      chats = stub_llm

      expect { parser.call(record: "Ada") }.to raise_error(Squishling::InvalidOutputError, /Deterministic/)
      expect(chats).to be_empty
    end

    it "raises what the Ruby raises, rather than handing it to the LLM" do
      chats = stub_llm
      klass = parser { def call(*) = raise(ArgumentError, "no comma") }

      expect { klass.call(record: "Ada") }.to raise_error(ArgumentError, "no comma")
      expect(chats).to be_empty
    end

    it "does not judge the Ruby return with squish_validate" do
      chats = stub_llm
      klass = parser do
        squish_validate { |_result, **| "never fine" }

        def call(*) = { name: "ada" }
      end

      expect(klass.call(record: "x").squished?).to be(false)
      expect(chats).to be_empty
    end
  end

  describe "squish_validate both_paths:" do
    # Ruby returns the record as the name; the check wants it capitalized.
    def checked(both_paths: nil, &)
      checker = ->(result, **) { "name must be capitalized" unless result.name.match?(/\A[A-Z]/) }
      Class.new do
        include Squishling

        purpose "Parse the record."
        output_schema { string :name }
        squish_validate(both_paths:, &checker)
        class_eval(&) if block_given?

        def call(record:) = { name: record }
      end
    end

    it "hands a Ruby return the check rejects to the LLM, with the draft and the problems" do
      chats = stub_llm({ "name" => "Ada" })

      klass = checked(both_paths: true)
      result = klass.call(record: "ada")

      expect(result.squished?).to be(true)
      expect(result.name).to eq("Ada")
      expect(result.class).to eq(klass.call(record: "Grace").class)
      context = context_of(chats.first)
      expect(context["ruby_draft"]).to eq("name" => "ada")
      expect(context["ruby_problems"]).to eq(["name must be capitalized"])
      expect(context).not_to have_key("ruby_error")
    end

    it "keeps a Ruby return the check accepts in Ruby" do
      chats = stub_llm

      expect(checked(both_paths: true).call(record: "Ada").squished?).to be(false)
      expect(chats).to be_empty
    end

    it "hands off a Ruby return the schema rejects, with or without a check declared" do
      chats = stub_llm({ "name" => "Ada" })
      klass = parser { squish_validate(both_paths: true) }

      result = klass.call(record: "Ada")

      expect(result.squished?).to be(true)
      expect(context_of(chats.first)["ruby_draft"]).to eq("nope" => "Ada")
      expect(context_of(chats.first)["ruby_problems"]).to all(be_a(String))
    end

    it "is switched on for every class by config.validate_both_paths" do
      Squishling.config.validate_both_paths = true
      stub_llm({ "name" => "Ada" })

      expect(checked.call(record: "ada").squished?).to be(true)
    end

    it "is overridden by the class, in either direction" do
      Squishling.config.validate_both_paths = true
      chats = stub_llm

      expect(checked(both_paths: false).call(record: "ada").squished?).to be(false)
      expect(chats).to be_empty

      Squishling.config.validate_both_paths = false
      stub_llm({ "name" => "Ada" })
      expect(checked(both_paths: true).call(record: "ada").squished?).to be(true)
    end

    it "lets a subclass change only the scope, keeping the check" do
      parent = checked(both_paths: false)
      child = Class.new(parent) { squish_validate(both_paths: true) }
      stub_llm({ "name" => "Ada" })

      expect(child.call(record: "ada").squished?).to be(true)
    end

    it "checks the LLM's answer with the same rules, keeping the Ruby failure as the cause when it fails" do
      stub_llm({ "name" => "grace" })

      expect { checked(both_paths: true).call(record: "ada") }
        .to raise_error(Squishling::InvalidOutputError, /LLM/) { |error|
          expect(error.errors).to eq(["name must be capitalized"])
          expect(error.cause).to be_a(Squishling::InvalidOutputError)
          expect(error.cause.message).to include("Deterministic")
        }
    end

    it "goes to squish_fallback when the LLM fails, and the fallback's return is not judged" do
      stub_llm("not json")
      klass = checked(both_paths: true) { squish_fallback { |_error, **| { name: "fallback" } } }

      result = klass.call(record: "ada")

      expect(result.name).to eq("fallback")
      expect(result.squished?).to be(false)
    end

    it "lets exceptions from the check itself propagate, not hand off" do
      chats = stub_llm
      klass = Class.new(checked(both_paths: true)) do
        squish_validate(both_paths: true) { |_result, **| raise IOError, "lookup down" }
      end

      expect { klass.call(record: "ada") }.to raise_error(IOError, "lookup down")
      expect(chats).to be_empty
    end

    it "lets a NotImplementedError from the check itself propagate, not route to the LLM" do
      chats = stub_llm
      klass = Class.new(checked(both_paths: true)) do
        squish_validate(both_paths: true) { |_result, **| raise NotImplementedError, "todo" }
      end

      expect { klass.call(record: "ada") }.to raise_error(NotImplementedError, "todo")
      expect(chats).to be_empty
    end

    it "does not validate what squish! already returned" do
      calls = 0
      stub_llm({ "name" => "Ada" })
      klass = parser do
        squish_validate(both_paths: true) { |_result, **| (calls += 1) && nil }

        def call(*)
          raise ArgumentError, "no"
        rescue ArgumentError
          squish!
        end
      end

      klass.call(record: "Ada")

      expect(calls).to eq(1) # the LLM's output, once
    end

    it "needs a boolean" do
      expect { checked(both_paths: :yes) }.to raise_error(Squishling::ConfigurationError, /both_paths:/)
      expect { Squishling.config.validate_both_paths = "yes" }
        .to raise_error(Squishling::ConfigurationError, /validate_both_paths/)
    end

    it "explains the hand-off in the purpose, after the declared sections" do
      chats = stub_llm({ "name" => "Ada" })

      parser do
        append_to_purpose "Names come first."
        squish_validate(both_paths: true)
      end.call(record: "Ada")

      expect(chats.first.instructions).to include("Parse the record.\n\nNames come first.\n\nThe Ruby implementation")
    end

    it "sends only the first part of a large draft" do
      chats = stub_llm({ "name" => "Ada" })

      parser do
        squish_validate(both_paths: true)
        define_method(:call) { |record:| { name: record, extra: record } }
      end.call(record: "x" * 5_000)

      draft = context_of(chats.first)["ruby_draft"]
      expect(draft).to be_a(String)
      expect(draft.size).to be <= Squishling::Invoker::MAX_FORWARDED_CHARS + 3
    end

    it "caps the problems like the LLM path does" do
      chats = stub_llm({ "name" => "Ada" })

      parser do
        squish_validate(both_paths: true)
        def call(*) = { name: "x", **(1..60).to_h { |index| [:"extra#{index}", index] } }
      end.call(record: "Ada")

      problems = context_of(chats.first)["ruby_problems"]
      expect(problems.size).to eq(Squishling::OutputCheck::MAX_ERRORS + 1)
      expect(problems.last).to include("more errors")
    end

    it "leaves out a draft JSON can't represent" do
      chats = stub_llm({ "name" => "Ada" })

      parser do
        squish_validate(both_paths: true)
        def call(*) = { name: Float::NAN }
      end.call(record: "Ada")

      expect(context_of(chats.first)).to have_key("ruby_problems")
      expect(context_of(chats.first)).not_to have_key("ruby_draft")
    end

    it "leaves out a draft that isn't plain data, rather than serializing it with its own to_json" do
      chats = stub_llm({ "name" => "Ada" })
      account = Class.new { def to_json(*) = '{"token":"sk-123"}' }

      parser do
        squish_validate(both_paths: true)
        define_method(:call) { |*| account.new }
      end.call(record: "Ada")

      expect(context_of(chats.first)).not_to have_key("ruby_draft")
      expect(chats.first.messages.first).not_to include("sk-123")
    end

    it "does not hand off what only looks like its own rejection: another squished object's" do
      inner = parser
      chats = stub_llm
      outer = Class.new(parser) do
        squish_validate(both_paths: true)
        define_method(:call) { |record:| inner.call(record:) }
      end

      expect { outer.call(record: "no comma") }.to raise_error(Squishling::InvalidOutputError, /Deterministic/)
      expect(chats).to be_empty
    end
  end

  describe "squish_rescue" do
    let(:raising) do
      parser do
        def call(record:)
          raise ArgumentError, "no comma in #{record.inspect}" unless record.include?(",")

          { name: record.split(",").first }
        end
      end
    end

    it "hands a named error to the LLM as its class and message, never a backtrace" do
      chats = stub_llm({ "name" => "Ada" })
      klass = Class.new(raising) { squish_rescue ArgumentError }

      result = klass.call(record: "Ada")

      expect(result.squished?).to be(true)
      expect(context_of(chats.first)).to eq(
        "ruby_error" => { "class" => "ArgumentError", "message" => 'no comma in "Ada"' }
      )
    end

    it "lets other errors propagate" do
      chats = stub_llm
      klass = Class.new(raising) { squish_rescue KeyError }

      expect { klass.call(record: "Ada") }.to raise_error(ArgumentError)
      expect(chats).to be_empty
    end

    it "accepts several classes, and a subclass of a named class" do
      stub_llm({ "name" => "A" }, { "name" => "B" })
      klass = Class.new(raising) { squish_rescue KeyError, StandardError }

      expect(klass.call(record: "Ada").squished?).to be(true)
      expect(Class.new(klass).call(record: "Ada").squished?).to be(true)
    end

    it "raises the LLM's failure with the Ruby error as the cause" do
      stub_llm(RubyLLM::ServerError.new("boom"))
      klass = Class.new(raising) { squish_rescue ArgumentError }

      expect { klass.call(record: "Ada") }.to raise_error(Squishling::LLMError)
    end

    it "goes to squish_fallback when the LLM fails" do
      stub_llm("not json")
      klass = Class.new(raising) do
        squish_rescue ArgumentError
        squish_fallback { |_error, **| { name: "fallback" } }
      end

      result = klass.call(record: "Ada")

      expect(result.name).to eq("fallback")
      expect(result.squished?).to be(false)
    end

    it "cuts a very long error message" do
      chats = stub_llm({ "name" => "Ada" })

      parser do
        squish_rescue IOError
        def call(*) = raise(IOError, "x" * 10_000)
      end.call(record: "Ada")

      expect(context_of(chats.first)["ruby_error"]["message"].size).to eq(Squishling::Invoker::MAX_FORWARDED_CHARS)
    end

    it "sends another squished object's failure as an error (class and message only), never its raw output" do
      inner = parser do
        purpose "Inner."
        squish_when { |**| true }
      end
      chats = stub_llm("SECRET raw output", { "name" => "Ada" })
      outer = Class.new(parser) do
        squish_rescue Squishling::InvalidOutputError
        define_method(:call) { |record:| inner.call(record:) }
      end

      outer.call(record: "no comma")

      context = context_of(chats.last)
      expect(context.keys).to eq(["ruby_error"])
      expect(JSON.generate(context)).not_to include("SECRET")
    end

    it "never takes a ConfigurationError" do
      chats = stub_llm
      klass = parser do
        squish_rescue StandardError
        def call(*) = raise(Squishling::ConfigurationError, "bad setup")
      end

      expect { klass.call(record: "Ada") }.to raise_error(Squishling::ConfigurationError, "bad setup")
      expect(chats).to be_empty
    end

    it "keeps raising its own errors in a class with no purpose to hand over" do
      chats = stub_llm
      klass = Class.new do
        include Squishling

        output_schema { string :name }
        squish_rescue ArgumentError

        def call(record:) = raise(ArgumentError, "typing only: #{record}")
      end

      expect { klass.call(record: "x") }.to raise_error(ArgumentError, "typing only: x")
      expect(chats).to be_empty
    end

    it "is not handed off twice when the method already did, or when the LLM's own failure comes back out" do
      chats = stub_llm(RubyLLM::ServerError.new("boom"))
      klass = parser do
        squish_rescue ArgumentError

        def call(*)
          raise ArgumentError, "no"
        rescue ArgumentError
          squish!(context: { record: "x" })
        end
      end

      expect { klass.call(record: "Ada") }.to raise_error(Squishling::LLMError)
      expect(chats.size).to eq(1)
    end

    it "is inherited by subclasses, and names add up across calls and down the chain" do
      stub_llm({ "name" => "Ada" })
      parent = Class.new(raising) { squish_rescue ArgumentError }
      child = Class.new(parent) { squish_rescue KeyError }
      child.send(:squish_rescue, IOError)

      expect(child.call(record: "Ada").squished?).to be(true)
      expect(child.squishling_rescue).to eq([ArgumentError, KeyError, IOError])
    end

    it "does not change that Ruby's own rejected return follows both_paths, even naming InvalidOutputError" do
      chats = stub_llm
      klass = parser { squish_rescue Squishling::InvalidOutputError }

      expect { klass.call(record: "Ada") }.to raise_error(Squishling::InvalidOutputError, /Deterministic/)
      expect(chats).to be_empty
    end

    it "needs StandardError classes, or options" do
      expect do
        parser do
          squish_rescue "ArgumentError"
        end
      end.to raise_error(Squishling::ConfigurationError, /StandardError/)
      expect { parser { squish_rescue ScriptError } }.to raise_error(Squishling::ConfigurationError, /StandardError/)
      expect { parser { squish_rescue } }.to raise_error(Squishling::ConfigurationError, /classes or options/)
      expect { parser { squish_rescue false } }.to raise_error(Squishling::ConfigurationError, /StandardError/)
    end

    it "logs the hand-off with the error class, never its message" do
      logger = instance_double(Logger, debug: nil)
      allow(logger).to receive(:warn)
      Squishling.config.logger = logger
      stub_llm({ "name" => "Ada" })

      parser do
        squish_rescue ArgumentError
        def call(record:) = raise(ArgumentError, "secret #{record}")
      end.call(record: "Ada")

      expect(logger).to have_received(:warn).with(/ruby raised ArgumentError, handing off/)
      expect(logger).not_to have_received(:warn).with(/secret/)
    end
  end

  describe "through a parent implementation (super)" do
    let(:base) do
      parser do
        squish_validate(both_paths: true)
        def call(*) = { nope: 1 }
      end
    end

    it "hands off the draft a parent returns that the schema rejects" do
      chats = stub_llm({ "name" => "Ada" })
      child = Class.new(base) { def call(*) = super }

      result = child.call(record: "Ada")

      expect(result.squished?).to be(true)
      expect(context_of(chats.first)["ruby_draft"]).to eq("nope" => 1)
    end

    it "raises it when both_paths is off" do
      chats = stub_llm
      base.squish_validate(both_paths: false)
      child = Class.new(base) { def call(*) = super }

      expect { child.call(record: "Ada") }.to raise_error(Squishling::InvalidOutputError, /Deterministic/)
      expect(chats).to be_empty
    end

    it "does not hand off when the child swallows the parent's rejection and returns something valid" do
      chats = stub_llm
      child = Class.new(base) do
        def call(*)
          super
        rescue Squishling::InvalidOutputError
          { name: "recovered" }
        end
      end

      expect(child.call(record: "Ada").squished?).to be(false)
      expect(chats).to be_empty
    end
  end

  describe "squish_rescue options" do
    it "send the squish! overrides, such as a stronger model, with every hand-off" do
      chats = stub_llm({ "name" => "Ada" })

      parser do
        squish_validate(both_paths: true)
        squish_rescue model: "claude-opus-5-5"
      end.call(record: "Ada")

      expect(chats.first.model).to eq("claude-opus-5-5")
    end

    it "do not apply to calls that never failed" do
      chats = stub_llm({ "name" => "Ada" })
      klass = parser do
        squish_rescue model: "claude-opus-5-5"
        squish_when { |record:| record == "llm" }
      end

      klass.call(record: "llm")

      expect(chats.first.model).not_to eq("claude-opus-5-5")
    end

    it "keep the named classes as inherited when they are given alone" do
      child = Class.new(Class.new(parser) { squish_rescue KeyError }) { squish_rescue model: "claude-opus-5-5" }

      expect(child.squishling_rescue).to eq([KeyError])
    end

    it "fail at declaration when invalid" do
      expect { parser { squish_rescue ArgumentError, provider: :openai } }
        .to raise_error(Squishling::ConfigurationError, /squish_rescue provider/)
      expect { parser { squish_rescue ArgumentError, context: { a: 1 } } }.to raise_error(ArgumentError)
    end

    it "replace a model declared earlier in the same class when an escalation follows" do
      chats = stub_llm({ "name" => "A" })
      klass = parser do
        squish_validate(both_paths: true)
        squish_rescue model: "claude-haiku-4-5"
        squish_rescue escalation: %w[claude-opus-5-5]
      end

      klass.call(record: "x")

      expect(chats.first.model).to eq("claude-opus-5-5")
    end

    it "add sections after the note, with false dropping what is above" do
      chats = stub_llm({ "name" => "A" }, { "name" => "B" })

      parser do
        squish_validate(both_paths: true)
        squish_rescue append_to_purpose: "From the class."
      end.call(record: "x")
      parser do
        squish_validate(both_paths: true)
        squish_rescue append_to_purpose: [false, "Only this."]
      end.call(record: "x")

      sections = chats.first.instructions.split("\n\n")
      expect(sections.index { |text| text.start_with?("The Ruby implementation") })
        .to be < sections.index("From the class.")
      expect(chats.last.instructions).to include("Parse the record.\n\nOnly this.\n\nThe input is a JSON")
      expect(chats.last.instructions).not_to include("The Ruby implementation")
    end

    it "accumulate down the chain" do
      parent = parser do
        squish_validate(both_paths: true)
        squish_rescue append_to_purpose: "Parent."
      end
      child = Class.new(parent) { squish_rescue append_to_purpose: "Child." }
      chats = stub_llm({ "name" => "A" })

      child.call(record: "x")

      expect(chats.first.instructions).to include("Parent.\n\nChild.\n\nThe input is a JSON")
    end

    it "mention the Ruby source only when it was appended" do
      chats = stub_llm({ "name" => "A" }, { "name" => "B" })

      parser { squish_validate(both_paths: true) }.call(record: "x")
      parser do
        squish_validate(both_paths: true)
        append_to_purpose "The Ruby:", self
      end.call(record: "x")

      expect(chats.first.instructions).not_to include(described_class::SOURCE_NOTE)
      expect(chats.last.instructions).to include(described_class::SOURCE_NOTE)
    end
  end
end
