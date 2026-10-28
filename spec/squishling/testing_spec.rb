# frozen_string_literal: true

require "squishling/testing"

RSpec.describe Squishling::Testing do
  include Squishling::Testing::RSpec

  let(:klass) do
    Class.new do
      include Squishling

      purpose "Extract the regex."
      output_schema do
        string :regex
      end
      squish_when { |text:| text.length > 3 }
      squish_validate { |result, **| result.regex.start_with?("[") ? "regex is not a valid Ruby regex" : nil }
      squish_fallback { |_error, **| { regex: "fallback" } }

      def self.to_s = "Extractor"

      def call(text:)
        result(regex: text)
      end
    end
  end

  describe "asserting what was sent" do
    it "passes when the model was sent exactly the declared arguments" do
      fake = fake_squishling { |llm| llm.step(:any).reply({ "regex" => "Run.*" }) }
      klass.call(text: "long text")

      assert_sent_arguments fake, { text: "long text" }
      assert_llm_calls fake, 1
    end

    it "fails with the arguments that were sent" do
      fake = fake_squishling { |llm| llm.step(:any).reply({ "regex" => "Run.*" }) }
      klass.call(text: "long text")

      expect { assert_sent_arguments fake, { text: "other" } }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /but it was sent \{"text" ?=> ?"long text"\}/)
      expect { assert_sent_arguments fake, { text: "x" }, request: 3 }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /only 1 were/)
      expect { assert_llm_calls fake, 2 }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /expected 2 LLM call\(s\), but there were 1/)
    end

    it "accepts the requests themselves" do
      fake = fake_squishling { |llm| llm.step(:any).reply({ "regex" => "Run.*" }) }
      klass.call(text: "long text")

      assert_sent_arguments fake.requests, { text: "long text" }
    end
  end

  describe "asserting no LLM call" do
    it "passes for the Ruby path and leaves the squished result unsquished" do
      result = nil
      assert_no_llm_call { result = klass.call(text: "abc") }

      expect(result.squished?).to be(false)
    end

    it "fails naming the squished method when the LLM was reached, even if the block rescued the error" do
      expect { assert_no_llm_call { klass.call(text: "long text") } }
        .to raise_error(RSpec::Expectations::ExpectationNotMetError, /Extractor#call reached the provider/)
      failure = Squishling::Testing::Checks.no_llm_call do
        klass.call(text: "long text")
      rescue Squishling::Testing::ProviderCallError
        nil
      end
      expect(failure).to include("Extractor#call")
    end

    it "puts the adapter back" do
      fake = fake_squishling { |llm| llm.step(:any).reply({ "regex" => "x" }) }
      assert_no_llm_call { klass.call(text: "abc") }

      expect(Squishling.config.adapter).to equal(fake)
    end
  end

  describe ".forbid_provider_calls!" do
    before { forbid_provider_calls! }

    it "raises at the call that reached the provider, which a squish_fallback can't absorb" do
      expect { klass.call(text: "long text") }
        .to raise_error(Squishling::Testing::ProviderCallError, /Extractor#call reached the provider/)
    end

    it "is replaced by installing a fake" do
      fake_squishling { |llm| llm.step(:any).reply({ "regex" => "x" }) }

      expect(klass.call(text: "long text").regex).to eq("x")
    end

    it "also stops a judgment" do
      adapter = Squishling.config.adapter

      expect { adapter.judge({}, questions: {}, step: nil, label: "Extractor#call") }
        .to raise_error(Squishling::Testing::ProviderCallError)
    end
  end

  describe ".reset!" do
    it "puts back only what the helpers changed" do
      Squishling.configure { |config| config.default_model = "app-model" }
      observer = Class.new { def around(_call) = yield }.new
      Squishling.config.observer = observer
      fake_squishling { |llm| llm.step(:any).reply({ "regex" => "x" }) }
      klass.call(text: "long text")
      described_class.reset!

      expect(Squishling.config.default_model).to eq("app-model")
      expect(Squishling.config.observer).to equal(observer)
      expect(Squishling.config.adapter).to be_nil
    end

    it "calls an observer the app configured while a fake is installed" do
      seen = []
      observer = Class.new do
        define_method(:around) { |call, &block| (seen << call.label) && block.call }
      end.new
      Squishling.config.observer = observer
      fake_squishling { |llm| llm.step(:any).reply({ "regex" => "x" }) }

      klass.call(text: "long text")

      expect(seen).to eq(["Extractor#call"])
    end

    it "leaves a config the app replaced alone" do
      fake_squishling
      Squishling.reset_config!

      expect { described_class.reset! }.not_to raise_error
    end

    it "forgets a replaced config, so a later install is put back too" do
      fake_squishling
      Squishling.reset_config!
      later = fake_squishling
      expect(Squishling.config.adapter).to equal(later)
      described_class.reset!

      expect(Squishling.config.adapter).to be_nil
      expect(Squishling.config.observer).to be_nil
    end

    it "leaves a setting the test assigned itself after the helpers did" do
      fake_squishling
      mine = Class.new(Squishling::Adapter::Base) { def complete(_request) = nil }.new
      Squishling.config.adapter = mine
      hook = ->(**) {}
      Squishling.config.squawk = hook
      described_class.reset!

      expect(Squishling.config.adapter).to equal(mine)
      expect(Squishling.config.squawk).to equal(hook)
    end

    it "keeps a named observer the app configured in the chain" do
      seen = []
      named = Class.new do
        define_method(:around) do |call, &block|
          seen << call.label
          block.call
        end
      end.new
      allow(Squishling::Observer).to receive(:resolve).and_call_original
      allow(Squishling::Observer).to receive(:resolve).with(:coolhand).and_return(named)
      Squishling.config.observer = :coolhand
      fake_squishling { |llm| llm.step(:any).reply({ "regex" => "x" }) }

      klass.call(text: "long text")

      expect(seen).to eq(["Extractor#call"])
    end

    it "keeps an observer assigned after the install, which hides the role from the adapter" do
      fake_squishling { |llm| llm.sample("a").reply({ "regex" => "x" }) }
      Squishling.config.observer = Class.new { def around(_call) = yield }.new

      expect { klass.call(text: "long text") }.to raise_error(Squishling::Testing::UnscriptedRequestError)
    end

    it "puts back an observer assigned between two installs, not the one before the first" do
      fake_squishling
      mine = Class.new { def around(_call) = yield }.new
      Squishling.config.observer = mine
      fake_squishling
      described_class.reset!

      expect(Squishling.config.observer).to equal(mine)
    end

    it "does not stack observers when installed twice" do
      first = fake_squishling
      second = fake_squishling

      expect(Squishling.config.observer.previous).to be_nil
      expect(Squishling.config.adapter).to equal(second)
      expect(Squishling.config.adapter).not_to equal(first)
    end
  end

  describe "squawk" do
    it "captures every attempt and puts the hook back" do
      fake_squishling { |llm| llm.step(:any).reply({ "regex" => "[bad" }, { "regex" => "ok" }) }
      klass.squishling escalation: [{ model: "flash", attempts: 2 }]
      previous = ->(**) {}
      Squishling.config.squawk = previous

      capture = with_squawk(capture_squawk) { klass.call(text: "long text") }

      expect(capture.calls.map { |call| call.metadata[:attempt] }).to eq([1, 2])
      expect(capture.calls.first.error).to be_a(Squishling::InvalidOutputError)
      expect(capture.calls.last).to have_attributes(output: { "regex" => "ok" }, error: nil)
      expect(Squishling.config.squawk).to equal(previous)
    end
  end

  describe "the Minitest mixin" do
    let(:host) do
      base = Class.new do
        attr_reader :failures

        def flunk(message) = (@failures ||= []) << message
        def after_teardown = nil
      end
      Class.new(base) { include Squishling::Testing::Minitest }.new
    end

    it "fails through the host's flunk and resets after teardown" do
      fake = host.fake_squishling { |llm| llm.step(:any).reply({ "regex" => "x" }) }
      klass.call(text: "long text")
      host.assert_sent_arguments(fake, { text: "nope" })
      host.after_teardown

      expect(host.failures.first).to include("was sent")
      expect(Squishling.config.adapter).to be_nil
    end
  end

  describe "requiring squishling" do
    it "does not load the test helpers" do
      lib = File.expand_path("../../lib", __dir__)
      script = 'require "squishling"; puts defined?(Squishling::Testing).inspect; require "squishling/testing"; ' \
               "puts defined?(Squishling::Testing::Adapter).inspect"

      output = IO.popen(["ruby", "-I", lib, "-e", script], &:read)

      expect(output.lines.map(&:strip)).to eq(["nil", "\"constant\""])
    end
  end
end
