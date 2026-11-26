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

  describe "next to squish_rescue" do
    let(:klass) do
      parser do
        squish_validate(both_paths: true)
        squish_rescue ArgumentError

        def call(record:)
          raise ArgumentError, "no comma" unless record.include?(",")

          record.start_with?("bad") ? { nope: record } : { name: record.split(",").first }
        end
      end
    end

    it "hands a raised error to the LLM through squish_rescue, and a rejected return through both_paths" do
      chats = stub_llm({ "name" => "A" }, { "name" => "B" })

      expect(klass.call(record: "Ada").squished?).to be(true)
      expect(klass.call(record: "bad,1").squished?).to be(true)
      expect(context_of(chats.first)).to eq("error" => { "class" => "ArgumentError", "message" => "no comma" })
      expect(context_of(chats.last).keys).to eq(%w[ruby_draft ruby_problems])
    end

    it "keeps a valid return in Ruby" do
      chats = stub_llm

      expect(klass.call(record: "Ada,1").squished?).to be(false)
      expect(chats).to be_empty
    end

    it "does not hand off an error nobody declared" do
      chats = stub_llm
      other = parser do
        squish_validate(both_paths: true)
        def call(*) = raise(KeyError, "missing")
      end

      expect { other.call(record: "x") }.to raise_error(KeyError)
      expect(chats).to be_empty
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
end
