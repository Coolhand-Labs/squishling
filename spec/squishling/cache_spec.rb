# frozen_string_literal: true

RSpec.describe Squishling::Cache do
  describe ".normalize" do
    it "keeps nil, true and false" do
      expect([nil, true, false].map { |value| described_class.normalize(value, "x") }).to eq([nil, true, false])
    end

    it "symbolizes and freezes a Hash of options" do
      options = described_class.normalize({ "ttl" => "1h" }, "x")

      expect(options).to eq(ttl: "1h")
      expect(options).to be_frozen
    end

    it "rejects anything else, and an explicit provider cache" do
      expect { described_class.normalize("yes", "x cache") }
        .to raise_error(Squishling::ConfigurationError, /x cache must be true, false, or a Hash.*"yes"/)
      expect { described_class.normalize({ id: "cachedContents/1" }, "x cache") }
        .to raise_error(Squishling::ConfigurationError, /id: \(an explicit provider cache\) isn't supported/)
    end
  end

  describe ".resolve" do
    it "lets the last level that declares a value win, and false beat an earlier true" do
      expect(described_class.resolve(true, nil, false)).to be(false)
      expect(described_class.resolve(false, nil, true)).to eq({})
      expect(described_class.resolve(true, nil, nil)).to eq({})
    end

    it "replaces an earlier Hash rather than merging into it" do
      expect(described_class.resolve({ ttl: "1h" }, { foo: 1 })).to eq(foo: 1)
    end

    it "is off when no level declares it" do
      expect(described_class.resolve(nil, nil)).to be(false)
    end
  end

  describe "through a squished call" do
    def classifier(**options, &)
      squishling_class do
        purpose "Classify."
        output_schema { string :label }
        squishling(**options) unless options.empty?
        class_eval(&) if block_given?
      end
    end

    # The cache the first request of one call carried.
    def requested(klass = classifier)
      chats = stub_llm({ "label" => "x" })
      klass.new.call(text: "hi")
      chats.first.cache
    end

    # Parses in Ruby and hands anything else to the LLM with the given squish! overrides.
    def handing_off(klass, **overrides)
      klass.class_eval do
        define_method(:call) do |text:|
          raise ArgumentError, text
        rescue ArgumentError
          squish!(**overrides)
        end
      end
      klass
    end

    it "is on by default, with the provider's default options" do
      expect(requested).to eq({})
    end

    it "is turned off by the configuration" do
      Squishling.config.default_cache = false

      expect(requested).to be(false)
    end

    it "passes a Hash from the configuration through" do
      Squishling.config.default_cache = { ttl: "1h" }

      expect(requested).to eq(ttl: "1h")
    end

    it "restores the default when the configuration is set to nil" do
      Squishling.config.default_cache = false
      Squishling.config.default_cache = nil

      expect(requested).to eq({})
    end

    it "rejects a bad configured value" do
      expect { Squishling.config.default_cache = "always" }
        .to raise_error(Squishling::ConfigurationError, /default_cache must be true, false, or a Hash/)
    end

    it "lets a class opt out, and a subclass inherit that or override it" do
      parent = classifier(cache: false)
      child = Class.new(parent)
      override = Class.new(parent) { squishling cache: { ttl: "1h" } }

      expect(requested(parent)).to be(false)
      expect(requested(child)).to be(false)
      expect(requested(override)).to eq(ttl: "1h")
    end

    it "lets a method override its class either way" do
      off = classifier { squish :call, cache: false }
      on = classifier(cache: false) { squish :call, cache: { ttl: "1h" } }

      expect(requested(off)).to be(false)
      expect(requested(on)).to eq(ttl: "1h")
    end

    it "lets a squish! call override the method and the class" do
      off = handing_off(classifier(cache: true) { squish :call, cache: true }, cache: false)
      on = handing_off(classifier(cache: false) { squish :call, cache: false }, cache: { ttl: "1h" })

      expect(requested(off)).to be(false)
      expect(requested(on)).to eq(ttl: "1h")
    end

    it "keeps the method's value when a squish! call says nothing" do
      klass = handing_off(classifier { squish :call, cache: false })

      expect(requested(klass)).to be(false)
    end

    it "lets an escalation step override the level's value, and carries it on every request" do
      klass = classifier(escalation: [{ model: "a", cache: false }, { model: "b" }])
      chats = stub_llm({ "bad" => 1 }, { "label" => "x" })

      klass.new.call(text: "hi")

      expect(chats.map(&:cache)).to eq([false, {}])
    end

    it "rejects a bad step value when the step is declared" do
      expect { classifier(escalation: [{ model: "a", cache: "yes" }]) }
        .to raise_error(Squishling::ConfigurationError, /\(a\) cache must be true, false, or a Hash/)
    end

    it "rejects a bad class, method or squish! value" do
      expect { classifier(cache: 1) }.to raise_error(Squishling::ConfigurationError, /cache must be true, false/)
      expect { classifier { squish :call, cache: 1 } }
        .to raise_error(Squishling::ConfigurationError, /squish cache must be true, false/)
      klass = handing_off(classifier, cache: 1)
      stub_llm
      expect { klass.new.call(text: "hi") }
        .to raise_error(Squishling::ConfigurationError, /squish! cache must be true, false/)
    end

    it "makes a step with no level cache request none" do
      path = [{ model: "j", attempts: 1, forward_rejected: true }]
      steps = Squishling::ModelPath.steps(path, provider: nil, params: {})

      expect(steps.first.cache).to be(false)
    end
  end
end
