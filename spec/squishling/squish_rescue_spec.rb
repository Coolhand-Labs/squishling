# frozen_string_literal: true

require "squishling/testing"

RSpec.describe Squishling, ".squish_rescue" do
  # Parses "name,..." in Ruby and raises ArgumentError for anything else.
  def parser(*errors, **options, &)
    Class.new do
      include Squishling

      purpose "Parse the record."
      output_schema { string :name }
      squish_rescue(*errors, **options) unless errors.empty?

      def call(record:)
        raise ArgumentError, "no comma in #{record.inspect}" unless record.include?(",")

        result(name: record.split(",").first)
      end

      class_eval(&) if block_given?
    end
  end

  it "keeps the Ruby result when nothing raises" do
    chats = stub_llm

    result = parser(ArgumentError).call(record: "Ada,1815")

    expect(result.name).to eq("Ada")
    expect(result.squished?).to be(false)
    expect(chats).to be_empty
  end

  it "hands a call to the LLM when the Ruby implementation raises a declared error" do
    chats = stub_llm({ "name" => "Ada" })

    result = parser(ArgumentError).call(record: "Ada born 1815")

    expect(result.squished?).to be(true)
    expect(result.name).to eq("Ada")
    expect(JSON.parse(chats.first.messages.first)).to eq(
      "arguments" => { "record" => "Ada born 1815" },
      "context" => { "error" => { "class" => "ArgumentError", "message" => 'no comma in "Ada born 1815"' } }
    )
  end

  it "returns the same result class from both paths" do
    stub_llm({ "name" => "Ada" })
    klass = parser(ArgumentError)

    expect(klass.call(record: "Ada born 1815").class).to eq(klass.call(record: "Ada,1815").class)
  end

  it "matches a subclass of a declared error" do
    stub_llm({ "name" => "Ada" })

    expect(parser(StandardError).call(record: "Ada").squished?).to be(true)
  end

  it "takes several errors in one declaration" do
    stub_llm({ "name" => "Ada" })
    klass = parser(KeyError, ArgumentError)

    expect(klass.call(record: "Ada").squished?).to be(true)
  end

  describe "an error that is not declared" do
    it "propagates and makes no LLM request" do
      chats = stub_llm

      expect { parser(KeyError).call(record: "Ada") }.to raise_error(ArgumentError, /no comma/)
      expect(chats).to be_empty
    end

    it "propagates from a class with no squish_rescue" do
      chats = stub_llm

      expect { parser.call(record: "Ada") }.to raise_error(ArgumentError)
      expect(chats).to be_empty
    end
  end

  describe "when StandardError is declared" do
    it "does not rescue Squishling's own errors from the Ruby path" do
      chats = stub_llm
      klass = parser(StandardError) do
        def call(**) = raise(Squishling::ConfigurationError, "bad setup")
      end

      expect { klass.call(record: "Ada") }.to raise_error(Squishling::ConfigurationError, "bad setup")
      expect(chats).to be_empty
    end

    it "does not rescue an LLM failure raised by a squished call to another object" do
      chats = stub_llm
      klass = parser(StandardError) do
        def call(**) = raise(Squishling::LLMError, "provider down")
      end

      expect { klass.call(record: "Ada") }.to raise_error(Squishling::LLMError, "provider down")
      expect(chats).to be_empty
    end

    it "does not run a second LLM attempt for a recursive call that already failed" do
      stub_llm("not json", "not json", "not json", "not json", "not json", "not json")
      klass = parser(StandardError) do
        def call(record:, depth: 0)
          raise ArgumentError, "inner" if depth.positive?

          call(record:, depth: 1)
        end
      end

      expect { klass.call(record: "Ada") }.to raise_error(Squishling::InvalidOutputError)
      expect(fake_adapter.chats.size).to eq(1)
    end

    it "does not rescue an invalid deterministic result, which is validated outside the rescue" do
      chats = stub_llm
      klass = parser(StandardError) do
        def call(**) = { nope: 1 }
      end

      expect { klass.call(record: "Ada") }.to raise_error(Squishling::InvalidOutputError)
      expect(chats).to be_empty
    end
  end

  describe "an error raised after squish! was called in the method" do
    it "propagates without a second hand-off" do
      chats = stub_llm({ "name" => "Ada" })
      klass = parser(ArgumentError) do
        def call(**)
          raise KeyError, "first"
        rescue KeyError
          squish!
          raise ArgumentError, "after"
        end
      end

      expect { klass.call(record: "Ada") }.to raise_error(ArgumentError, "after")
      expect(chats.size).to eq(1)
    end
  end

  describe "a squished method that calls another on the same object" do
    it "hands off only the method that raised" do
      stub_llm({ "name" => "from other" })
      klass = squishling_class do
        squish_rescue ArgumentError
        squish :other, purpose: "Other." do
          string :name
        end
        purpose "Call."
        output_schema { string :name }

        def call = result(name: other.name)
        def other = raise(ArgumentError, "bad")
      end

      result = klass.new.call

      expect(result.name).to eq("from other")
      expect(result.squished?).to be(false)
    end
  end

  describe "the LLM path" do
    it "raises the LLM failure, caused by the rescued error, when there is no fallback" do
      stub_llm("not json", "not json", "not json")

      expect { parser(ArgumentError).call(record: "Ada") }.to raise_error(Squishling::InvalidOutputError) do |error|
        expect(error.cause).to be_a(ArgumentError)
      end
    end

    it "uses squish_fallback when the LLM fails" do
      stub_llm("not json", "not json", "not json")
      klass = parser(ArgumentError) { squish_fallback { |_error, **| { name: "fallback" } } }

      expect(klass.call(record: "Ada").name).to eq("fallback")
    end

    it "does not rescue an error that the LLM path raises" do
      stub_llm({ "name" => "Ada" })
      klass = parser(ArgumentError) do
        squish_validate { |_result, **| raise ArgumentError, "from validate" }
      end

      expect { klass.call(record: "Ada") }.to raise_error(ArgumentError, "from validate")
    end

    it "does not rescue an error that squish_when raises" do
      chats = stub_llm
      klass = parser(ArgumentError) { squish_when { |**| raise ArgumentError, "from squish_when" } }

      expect { klass.call(record: "Ada,1") }.to raise_error(ArgumentError, "from squish_when")
      expect(chats).to be_empty
    end

    it "does not rescue an error that squish_fallback raises" do
      stub_llm("not json", "not json", "not json")
      klass = parser(ArgumentError) { squish_fallback { |_error, **| raise ArgumentError, "from fallback" } }

      expect { klass.call(record: "Ada") }.to raise_error(ArgumentError, "from fallback")
    end
  end

  describe "options" do
    it "names the context key with as:" do
      chats = stub_llm({ "name" => "Ada" })

      parser(ArgumentError, as: :parse_error).call(record: "Ada")

      expect(JSON.parse(chats.first.messages.first)["context"].keys).to eq(["parse_error"])
    end

    it "adds append_to_purpose: to the prompt of a rescued call" do
      chats = stub_llm({ "name" => "Ada" })
      klass = parser(ArgumentError, append_to_purpose: "The Ruby parser failed; the error is in the context.")

      klass.call(record: "Ada")

      expect(chats.first.instructions).to include("The Ruby parser failed; the error is in the context.")
    end

    it "sends a context: alongside the error" do
      chats = stub_llm({ "name" => "Ada" })

      parser(ArgumentError, context: { source: "csv" }).call(record: "Ada")

      expect(JSON.parse(chats.first.messages.first)["context"])
        .to include("source" => "csv", "error" => hash_including("class" => "ArgumentError"))
    end

    it "takes the model: of squish!" do
      chats = stub_llm({ "name" => "Ada" })

      parser(ArgumentError, model: "rescue-model").call(record: "Ada")

      expect(chats.first.model).to eq("rescue-model")
    end
  end

  describe "where it applies" do
    it "covers a method declared with squish, not only call" do
      stub_llm({ "name" => "Ada" })
      klass = squishling_class do
        squish_rescue ArgumentError
        squish :parse, purpose: "Parse the record." do
          string :name
        end

        def parse(record) = raise(ArgumentError, "bad #{record}")
      end

      expect(klass.new.parse("x").squished?).to be(true)
    end

    it "is inherited by a subclass" do
      stub_llm({ "name" => "Ada" })

      expect(Class.new(parser(ArgumentError)).call(record: "Ada").squished?).to be(true)
    end

    it "lets a subclass declare its own options for the same error" do
      chats = stub_llm({ "name" => "Ada" })
      child = Class.new(parser(ArgumentError, append_to_purpose: "parent note")) do
        squish_rescue ArgumentError, append_to_purpose: "child note"
      end

      child.call(record: "Ada")

      expect(chats.first.instructions).to include("child note")
      expect(chats.first.instructions).not_to include("parent note")
    end

    it "uses the first declaration in a class that matches, as rescue does" do
      chats = stub_llm({ "name" => "Ada" })
      klass = parser(ArgumentError, append_to_purpose: "first note") do
        squish_rescue StandardError, append_to_purpose: "second note"
      end

      klass.call(record: "Ada")

      expect(chats.first.instructions).to include("first note")
      expect(chats.first.instructions).not_to include("second note")
    end

    it "rescues an error raised by a parent implementation reached through super" do
      stub_llm({ "name" => "Ada" })
      child = Class.new(parser(ArgumentError)) do
        def call(record:) = super(record: record.strip)
      end

      expect(child.call(record: "Ada").squished?).to be(true)
    end

    it "still lets squish! be called from the method's own rescue" do
      stub_llm({ "name" => "Ada" })
      klass = Class.new(parser(KeyError)) do
        def call(**)
          raise ArgumentError, "bad"
        rescue ArgumentError => e
          squish!(context: { parse_error: e })
        end
      end

      expect(klass.call(record: "Ada").squished?).to be(true)
    end
  end

  describe "declaration errors" do
    it "rejects no errors" do
      expect { squishling_class { squish_rescue } }.to raise_error(Squishling::ConfigurationError, /error class/)
    end

    it "rejects something that is not an exception class" do
      expect { squishling_class { squish_rescue "ArgumentError" } }
        .to raise_error(Squishling::ConfigurationError, /exception class/)
      expect { squishling_class { squish_rescue String } }
        .to raise_error(Squishling::ConfigurationError, /exception class/)
    end

    it "rejects an exception that is not a StandardError, such as Exception, SystemExit, or Interrupt" do
      [Exception, SystemExit, Interrupt, NoMemoryError].each do |error|
        expect { squishling_class { squish_rescue error } }
          .to raise_error(Squishling::ConfigurationError, /StandardError/)
      end
    end

    it "rejects Squishling's own errors, which are never sent to the LLM" do
      [Squishling::Error, Squishling::ConfigurationError, Squishling::LLMError].each do |error|
        expect { squishling_class { squish_rescue error } }
          .to raise_error(Squishling::ConfigurationError, /Squishling's own errors/)
      end
    end

    it "rejects NotImplementedError, which already sends a call to the LLM" do
      expect { squishling_class { squish_rescue NotImplementedError } }
        .to raise_error(Squishling::ConfigurationError, /NotImplementedError/)
    end

    it "rejects a bad option value at declaration" do
      expect { squishling_class { squish_rescue ArgumentError, model: 123 } }
        .to raise_error(Squishling::ConfigurationError, /squish_rescue.*model/)
    end

    it "rejects an as: that is not a non-empty Symbol or String" do
      [nil, 1, ""].each do |name|
        expect { squishling_class { squish_rescue ArgumentError, as: name } }
          .to raise_error(Squishling::ConfigurationError, /squish_rescue as:/)
      end
    end

    it "rejects a context: that is not a Hash" do
      expect { squishling_class { squish_rescue ArgumentError, context: "x" } }
        .to raise_error(Squishling::ConfigurationError, /context/)
    end

    it "rejects an unknown option" do
      expect { squishling_class { squish_rescue ArgumentError, bogus: 1 } }.to raise_error(ArgumentError, /bogus/)
    end
  end

  describe "declaration errors that name the declaration" do
    it "starts every one with Klass#squish_rescue" do
      [-> { squish_rescue }, -> { squish_rescue ArgumentError, as: "" }, -> { squish_rescue ArgumentError, model: 1 }]
        .each do |declare|
        expect { squishling_class { instance_exec(&declare) } }
          .to raise_error(Squishling::ConfigurationError, /#squish_rescue/)
      end
    end

    it "rejects a context: that already has the as: key, which the error would replace" do
      expect { squishling_class { squish_rescue ArgumentError, context: { error: "hint" } } }
        .to raise_error(Squishling::ConfigurationError, /context: .*error.*as:/)
      expect { squishling_class { squish_rescue ArgumentError, as: "failure", context: { failure: "hint" } } }
        .to raise_error(Squishling::ConfigurationError, /context: .*failure.*as:/)
    end

    it "keeps a context: whose keys differ from as:" do
      chats = stub_llm({ "name" => "Ada" })

      parser(ArgumentError, context: { vendor: "acme" }).call(record: "Ada born 1815")

      context = JSON.parse(chats.first.messages.first)["context"]
      expect(context).to include("vendor" => "acme", "error" => a_kind_of(Hash))
    end
  end

  describe "an error that rescue matches with === but is_a? does not" do
    it "hands the call to the LLM like any other declared error" do
      stub_llm({ "name" => "Ada" })
      errno_twin = Class.new(SystemCallError) { const_set(:Errno, Errno::ENOENT::Errno) }
      klass = parser(Errno::ENOENT) do
        define_method(:call) { |**| raise errno_twin, "no file" }
      end

      expect(klass.call(record: "Ada").squished?).to be(true)
    end
  end

  describe "the errors the test helpers raise" do
    it "are never rescued, even under a declared StandardError" do
      chats = stub_llm
      klass = parser(StandardError) do
        def call(**) = raise(Squishling::Testing::UnscriptedRequestError, "no answers left")
      end

      expect { klass.call(record: "Ada") }.to raise_error(Squishling::Testing::UnscriptedRequestError)
      expect(chats).to be_empty
    end
  end

  describe "the log line for a rescued error" do
    it "names the declared error's class and never its message" do
      log = StringIO.new
      Squishling.configure { |c| c.logger = Logger.new(log) }
      stub_llm({ "name" => "Ada" })

      parser(ArgumentError).call(record: "Ada born 1815")

      expect(log.string).to include("-> LLM (squish_rescue ArgumentError)")
      expect(log.string).not_to include("no comma")
    end
  end

  describe "Squishling.verify" do
    it "is clean for a valid declaration" do
      expect(Squishling.verify(parser(ArgumentError)).problems).to be_empty
    end
  end
end
