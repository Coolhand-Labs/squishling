# frozen_string_literal: true

require_relative "../fixtures/sourced_parser"

RSpec.describe Squishling, "#squish!" do
  # Parses "name,..." in Ruby; anything else is handed to the LLM with the error and the given overrides.
  def parser(**overrides, &)
    Class.new do
      include Squishling

      purpose "Parse the record."
      output_schema { string :name }
      define_method(:overrides) { overrides }
      class_eval(&) if block_given?

      def call(record:)
        raise ArgumentError, "no comma in #{record.inspect}" unless record.include?(",")

        result(name: record.split(",").first)
      rescue ArgumentError => e
        squish!(context: { parse_error: e }, **overrides)
      end
    end
  end

  it "keeps the Ruby result when nothing fails" do
    chats = stub_llm

    result = parser.call(record: "Ada,1815")

    expect(result.name).to eq("Ada")
    expect(result.squished?).to be(false)
    expect(chats).to be_empty
  end

  it "hands the call to the LLM from a rescue and returns the same result type" do
    chats = stub_llm({ "name" => "Ada" })

    klass = parser
    result = klass.call(record: "Ada born 1815")
    ruby = klass.call(record: "Ada,1815")

    expect(result.squished?).to be(true)
    expect(result.name).to eq("Ada")
    expect(result.class).to eq(ruby.class)
    expect(JSON.parse(chats.first.messages.first)).to eq(
      "arguments" => { "record" => "Ada born 1815" },
      "context" => { "parse_error" => { "class" => "ArgumentError",
                                        "message" => 'no comma in "Ada born 1815"' } }
    )
  end

  it "sends exceptions nested in context as their class and message" do
    chats = stub_llm({ "name" => "Ada" })

    anonymous = Class.new(IndexError)
    parser(context: { attempts: [KeyError.new("a"), { last: anonymous.new("b") }] }).call(record: "Ada")

    expect(JSON.parse(chats.first.messages.first)["context"]["attempts"])
      .to eq([{ "class" => "KeyError", "message" => "a" }, { "last" => { "class" => "IndexError", "message" => "b" } }])
  end

  it "sends the call's context alongside squish_context, overriding a same-named value" do
    klass = parser do
      squish_context :tier, :parse_error

      def tier = "gold"
      def parse_error = "declared"
    end
    chats = stub_llm({ "name" => "Ada" })

    klass.call(record: "Ada")

    expect(JSON.parse(chats.first.messages.first)["context"])
      .to eq("tier" => "gold", "parse_error" => { "class" => "ArgumentError", "message" => 'no comma in "Ada"' })
  end

  it "adds per-call append_to_purpose to the declared ones" do
    klass = parser(append_to_purpose: "The Ruby parser failed.") { append_to_purpose "Class." }
    chats = stub_llm({ "name" => "Ada" })

    klass.call(record: "Ada")

    expect(chats.first.instructions).to start_with("Parse the record.\n\nClass.\n\nThe Ruby parser failed.\n\n")
  end

  it "drops the declared append_to_purpose for one call with false" do
    klass = parser(append_to_purpose: false) { append_to_purpose "Class." }
    chats = stub_llm({ "name" => "Ada" })

    klass.call(record: "Ada")

    expect(chats.first.instructions).to eq("Parse the record.\n\n#{Squishling::Invoker::INPUT_NOTE}")
  end

  it "replaces the purpose for one call" do
    chats = stub_llm({ "name" => "Ada" })

    parser(purpose: "Recover the name.").call(record: "Ada")

    expect(chats.first.instructions).to start_with("Recover the name.\n\n")
  end

  it "hands off to another model and params for one call" do
    klass = parser(model: "gpt-unknown", provider: :openai, params: { top_p: 0.5 }) do
      squishling model: "claude-haiku-4-5", params: { temperature: 0.2 }
    end
    chats = stub_llm({ "name" => "Ada" })

    klass.call(record: "Ada")

    expect(chats.first.model).to eq("gpt-unknown")
    expect(chats.first.options).to eq(provider: :openai, assume_model_exists: true)
    expect(chats.first.generation).to eq(temperature: 0.2, provider_options: { top_p: 0.5 })
  end

  it "keeps a method-level nil that unsets a class param when adding call params" do
    klass = parser(params: { top_p: 0.5 }) do
      squishling params: { temperature: 0.2 }
      squish :call, params: { temperature: nil }
    end
    chats = stub_llm({ "name" => "Ada" })

    klass.call(record: "Ada")

    expect(chats.first.generation).to eq(provider_options: { top_p: 0.5 })
  end

  it "can hand off again to a stronger model after a failed attempt" do
    klass = Class.new do
      include Squishling

      purpose "Parse."
      output_schema { string :name }

      def call(record:)
        squish!(model: "small-model", provider: :openai)
      rescue Squishling::LLMError
        squish!(model: "big-model", provider: :openai, context: { record_length: record.length })
      end
    end
    chats = stub_llm(RubyLLM::ServiceUnavailableError.new("down"), { "name" => "Ada" })

    result = klass.call(record: "Ada")

    expect(result.squished?).to be(true)
    expect(chats.map(&:model)).to eq(%w[small-model big-model])
    expect(JSON.parse(chats.last.messages.first)["context"]).to eq("record_length" => 3)
  end

  it "accepts an escalation: for this call, replacing the declared model" do
    klass = Class.new do
      include Squishling

      squishling model: "declared-model"
      purpose "Parse."
      output_schema { string :name }

      def call(**) = squish!(escalation: [{ model: "small-model", attempts: 2 }, "big-model"], provider: :openai)
    end
    chats = stub_llm(nil, RubyLLM::ServiceUnavailableError.new("down"), { "name" => "Ada" })

    expect(klass.call(record: "Ada").name).to eq("Ada")
    expect(chats.map(&:model)).to eq(%w[small-model big-model]) # attempts 1-2 share a chat
    expect(chats.first.messages.size).to eq(2)
    expect(chats.map(&:options)).to all(include(provider: :openai))
  end

  it "rejects model: and escalation: together" do
    klass = Class.new do
      include Squishling

      purpose "Parse."
      output_schema { string :name }

      def call(**) = squish!(model: "a", escalation: %w[b])
    end

    expect { klass.call(record: "Ada") }.to raise_error(Squishling::ConfigurationError, /not both/)
  end

  it "uses the declared fallback when the LLM fails" do
    klass = parser { squish_fallback { |_error, record:| { name: "fallback for #{record}" } } }
    stub_llm(nil, nil)

    result = klass.call(record: "Ada")

    expect(result.name).to eq("fallback for Ada")
    expect(result.squished?).to be(false)
  end

  it "raises the LLM failure, caused by the rescued error, when there's no fallback" do
    stub_llm(RubyLLM::ServiceUnavailableError.new("down"))

    expect { parser.call(record: "Ada") }.to raise_error(Squishling::LLMError) { |error|
      expect(error.cause).to be_a(RubyLLM::ServiceUnavailableError)
      expect(error.cause.cause).to be_a(ArgumentError)
    }
  end

  it "works from a helper method called by the squished method" do
    klass = Class.new do
      include Squishling

      purpose "Parse."
      output_schema { string :name }

      def call(record:) = recover(record)

      def recover(_record) = squish!
    end
    stub_llm({ "name" => "Ada" })

    expect(klass.call(record: "Ada").squished?).to be(true)
  end

  it "works from a parent implementation reached through super" do
    child = Class.new(parser) do
      def call(record:)
        super(record: record.strip)
      end
    end
    chats = stub_llm({ "name" => "Ada" })

    expect(child.call(record: " Ada ").squished?).to be(true)
    expect(JSON.parse(chats.first.messages.first)["arguments"]).to eq("record" => " Ada ")
  end

  it "propagates a NotImplementedError from its fallback instead of making a second LLM call" do
    klass = parser { squish_fallback { |error, **| raise NotImplementedError, "no fallback for #{error.class}" } }
    chats = stub_llm(nil, nil, { "name" => "second call" })

    expect { klass.call(record: "Ada") }.to raise_error(NotImplementedError, /no fallback/)
    expect(chats.size).to eq(1)
  end

  it "sends an exception passed as an argument as its class and message" do
    klass = Class.new do
      include Squishling

      purpose "Explain."
      output_schema { string :name }

      def call(error:)
        raise error
      rescue KeyError
        squish!
      end
    end
    chats = stub_llm({ "name" => "Ada" })

    klass.call(error: KeyError.new("missing"))

    expect(JSON.parse(chats.first.messages.first))
      .to eq("arguments" => { "error" => { "class" => "KeyError", "message" => "missing" } })
  end

  it "sends a recursive call's own inputs" do
    klass = Class.new do
      include Squishling

      purpose "Parse the record."
      output_schema { string :name }

      # Parses each ";"-separated record by calling itself.
      def call(record:)
        return result(name: record.split(";").map { |part| call(record: part).name }.join("+")) if record.include?(";")
        raise ArgumentError, "no comma" unless record.include?(",")

        result(name: record.split(",").first)
      rescue ArgumentError => e
        squish!(context: { parse_error: e })
      end
    end
    chats = stub_llm({ "name" => "X" })

    expect(klass.call(record: "Ada,1;garbage").name).to eq("Ada+X")
    expect(JSON.parse(chats.first.messages.first)["arguments"]).to eq("record" => "garbage")
  end

  it "raises outside a squished method" do
    expect { parser.new.squish! }.to raise_error(Squishling::Error, /squish! called outside a squished method/)
  end

  it "raises when called from a fallback, instead of recursing" do
    klass = parser { squish_fallback { |_error, **| squish! } }
    stub_llm(nil, nil)

    expect { klass.call(record: "Ada") }.to raise_error(Squishling::Error, /already on the LLM path/)
  end

  it "raises when called from squish_when" do
    klass = parser { squish_when { |**| squish! } }
    stub_llm

    expect { klass.call(record: "Ada") }.to raise_error(Squishling::Error, /not from squish_when/)
  end

  it "rejects a provider without a model, and a non-Hash context" do
    expect { parser(provider: :openai).call(record: "Ada") }
      .to raise_error(Squishling::ConfigurationError, /provider: needs a model:/)

    klass = parser
    klass.define_method(:call) { |record:| squish!(context: record) }
    expect { klass.call(record: "Ada") }.to raise_error(Squishling::ConfigurationError, /context: must be a Hash/)

    klass.define_method(:call) { |record:| squish!(context: { 1 => record }) }
    expect { klass.call(record: "Ada") }.to raise_error(Squishling::ConfigurationError, /String or Symbol keys/)
  end

  it "rejects reserved params" do
    expect { parser(params: { model: "x" }).call(record: "Ada") }
      .to raise_error(Squishling::ConfigurationError, /model can't be set through params/)
  end

  it "runs the fixture parser's rescue path with its class source appended" do
    chats = stub_llm({ "name" => "Ada" })

    expect(SourcedParser.call(record: "").squished?).to be(true)
    expect(chats.first.instructions).to include("# Source: SourcedParser", "The Ruby parser failed on this record.")
    expect(JSON.parse(chats.first.messages.first)["context"])
      .to eq("parse_error" => { "class" => "ArgumentError", "message" => "empty record" })
  end
end
