# frozen_string_literal: true

require_relative "../fixtures/sourced_parser"
require_relative "../fixtures/sourced_parser_extension"

RSpec.describe Squishling::Appendices do
  def base_class(&)
    Class.new do
      include Squishling

      instructions "Base."
      output_schema { string :value }
      squish_when { true }
      class_eval(&) if block_given?
    end
  end

  def system_prompt(klass, method = :call, *args, response: { "value" => "ok" }, **kwargs)
    chats = stub_llm(response)
    klass.new.public_send(method, *args, **kwargs)
    chats.first.instructions
  end

  it "appends strings after the instructions and before the input note" do
    klass = base_class { append_instructions "First.", "Second." }

    expect(system_prompt(klass)).to eq("Base.\n\nFirst.\n\nSecond.\n\n#{Squishling::Invoker::INPUT_NOTE}")
  end

  it "accepts an Array through the squishling option" do
    klass = base_class { squishling append_instructions: ["From squishling."] }

    expect(system_prompt(klass)).to start_with("Base.\n\nFrom squishling.\n\n")
  end

  it "sends a class's source when given the class itself" do
    prompt = system_prompt(SourcedParser, record: "", response: { "name" => "ok" })

    expect(prompt).to start_with("Parse the record.\n\nThe Ruby parser for well-formed records:\n\n" \
                                 "````ruby\n# Source: SourcedParser\nclass SourcedParser\n  include Squishling\n")
    expect(prompt).to include("  def call(record:)\n", "  def self.build = new\n")
    expect(prompt).to include("class SourcedParser\n  FENCE = \"```json\"\n",
      "  def normalize(text) = text.strip\nend\n````")
  end

  it "sends an anonymous class's own defs, without the rest of its body" do
    klass = Class.new do
      include Squishling

      instructions "Base."
      append_instructions self
      output_schema { string :value }

      def call = raise(NotImplementedError)
    end

    expect(system_prompt(klass))
      .to include("```ruby\n# Source: (anonymous class)\ndef call = raise(NotImplementedError)\n```")
  end

  it "sends one method's source, beneath Squishling's wrapper" do
    klass = base_class { append_instructions instance_method(:call) }
    klass.class_eval do
      def call
        { value: "ruby" }
      end
    end

    expect(system_prompt(klass))
      .to include("# Source: (anonymous class)#call\ndef call\n  { value: \"ruby\" }\nend\n```")
  end

  it "evaluates procs against the instance on each call" do
    klass = base_class do
      append_instructions -> { "Tier: #{tier}." }, -> {}, -> { strict? && "Be strict." }, -> { ["A.", "B."] }
      append_instructions { "From a block." }

      def tier = "gold"
      def strict? = false
    end

    expect(system_prompt(klass)).to start_with("Base.\n\nTier: gold.\n\nA.\n\nB.\n\nFrom a block.\n\n")
  end

  it "adds a subclass's items to the parent's" do
    parent = base_class { append_instructions "Parent." }
    child = Class.new(parent) { append_instructions "Child." }

    expect(system_prompt(child)).to start_with("Base.\n\nParent.\n\nChild.\n\n")
    expect(system_prompt(parent)).to start_with("Base.\n\nParent.\n\n#{Squishling::Invoker::INPUT_NOTE}")
  end

  it "drops inherited items with false" do
    parent = base_class { append_instructions "Parent." }
    child = Class.new(parent) { append_instructions false, "Child only." }

    expect(system_prompt(child)).to eq("Base.\n\nChild only.\n\n#{Squishling::Invoker::INPUT_NOTE}")
  end

  it "adds per-method items to the class's, or replaces them with false" do
    klass = base_class do
      append_instructions "Class."
      squish :added, append_instructions: "Method.", when: -> { true }
      squish :replaced, append_instructions: [false, "Method only."], when: -> { true }
      squish :dropped, append_instructions: false, when: -> { true }
    end

    expect(system_prompt(klass, :added)).to start_with("Base.\n\nClass.\n\nMethod.\n\n")
    expect(system_prompt(klass, :replaced)).to start_with("Base.\n\nMethod only.\n\n")
    expect(system_prompt(klass, :dropped)).to eq("Base.\n\n#{Squishling::Invoker::INPUT_NOTE}")
  end

  it "rejects unsupported items when declared" do
    expect { base_class { append_instructions 42 } }
      .to raise_error(Squishling::ConfigurationError, /items must be Strings.*got 42/)
    expect { base_class { squish :x, append_instructions: [:symbol] } }
      .to raise_error(Squishling::ConfigurationError, /got :symbol/)
  end

  it "rejects unsupported values returned by a proc" do
    klass = base_class { append_instructions -> { 42 } }
    hash = base_class { append_instructions -> { { a: 1 } } }
    object = base_class { append_instructions -> { Object.new } }

    expect { system_prompt(klass) }.to raise_error(Squishling::ConfigurationError, /proc.*or methods \(got 42\)/)
    expect { system_prompt(hash) }.to raise_error(Squishling::ConfigurationError, /\(got an instance of Hash\)/)
    expect { system_prompt(object) }.to raise_error(Squishling::ConfigurationError, /\(got an instance of Object\)/)
  end

  it "raises ConfigurationError when the source isn't available" do
    # Code generated at runtime has no file to read.
    generated = Class.new.tap { |k| k.class_eval("def x = 1", "(generated)", 1) } # rubocop:disable Style/EvalWithLocation
    klass = base_class { append_instructions generated }

    expect { system_prompt(klass) }.to raise_error(Squishling::ConfigurationError, /source for .* isn't available/)
  end

  describe Squishling::Source do
    it "dedents nested classes" do
      expect(described_class.render(SourcedHelpers::Normalizer))
        .to eq("```ruby\n# Source: SourcedHelpers::Normalizer\nclass Normalizer\n  def self.clean(text)\n    " \
               "text.strip\n  end\nend\n```")
    end

    it "sends a class assigned from Class.new by its constant" do
      expect(described_class.render(SourcedConstant))
        .to eq("```ruby\n# Source: SourcedConstant\nClass.new do\n  def call = :constant\nend\n```")
    end

    it "doesn't send an unrelated block that defines one of a named class's methods" do
      expect(described_class.render(SourcedTarget))
        .to eq("```ruby\n# Source: SourcedTarget\nclass SourcedTarget; end\n```")
    end

    it "finds an aliased method's def by its original name" do
      klass = Class.new do
        def original = :source

        alias_method :aliased, :original
      end

      expect(described_class.render(klass.instance_method(:aliased)))
        .to eq("```ruby\n# Source: (anonymous class)#original\ndef original = :source\n```")
    end

    it "labels a plain object's singleton method by its class" do
      object = Object.new
      def object.greet = :hi

      expect(described_class.render(object.method(:greet)))
        .to start_with("```ruby\n# Source: (Object instance).greet\ndef object.greet = :hi\n")
    end

    it "finds a class nested in an anonymous namespace" do
      namespace = Module.new
      namespace.const_set(:Parser, Class.new { def call = :nested })

      expect(described_class.render(namespace::Parser)).to end_with("\ndef call = :nested\n```")
    end

    it "finds a class with a temporary name" do
      klass = Class.new { def call = :temporary }.set_temporary_name("parser<tmp>")

      expect(described_class.render(klass)).to eq("```ruby\n# Source: parser<tmp>\ndef call = :temporary\n```")
    end

    it "doesn't send a larger block whose factory method defined an anonymous class's methods" do
      factory = Module.new do
        def self.make
          klass = Class.new
          klass.define_method(:shown) { 1 }
          klass
        end
      end

      expect { described_class.render(factory.make) }
        .to raise_error(Squishling::ConfigurationError, /source for .* isn't available/)
    end

    it "doesn't send an unrelated class with the same short name that reopens it" do
      source = described_class.render(Billing::Client)

      expect(source).to eq("```ruby\n# Source: Billing::Client\nclass Client\n  def charge = :charged\nend\n```")
    end

    it "reads source as UTF-8 whatever the default external encoding" do
      previous = Encoding.default_external
      Encoding.default_external = Encoding::US_ASCII

      expect(described_class.render(EncodedParser)).to include("class EncodedParser # parses “smart quotes”")
    ensure
      Encoding.default_external = previous
    end

    it "raises ConfigurationError when a source file can't be read" do
      klass = Class.new { def call = :unreadable }
      allow(File).to receive(:read).and_raise(Errno::EACCES)

      expect { described_class.render(klass) }.to raise_error(Squishling::ConfigurationError, /can't read .*EACCES/)
    end

    it "includes an anonymous class's private class methods" do
      klass = Class.new do
        private_class_method def self.helper = :hidden
      end

      expect(described_class.render(klass)).to include("def self.helper = :hidden")
    end

    it "handles a class that defines its own self.method" do
      klass = Class.new do
        def self.method = :get

        def call = :request
      end

      expect(described_class.render(klass)).to include("def self.method = :get", "def call = :request")
    end

    it "sends only an anonymous class's own def when it's added from inside another block" do
      big = Module.new do
        const_set(:SECRET_TOKEN, "s3cr3t")

        def self.attach(klass) = klass.class_eval { def z = 1 }
      end
      klass = Class.new.tap { |k| big.attach(k) }

      expect(described_class.render(klass)).to eq("```ruby\n# Source: (anonymous class)\ndef z = 1\n```")
    end

    it "skips a module prepended to the singleton class" do
      tracing = Module.new do
        const_set(:TRACE_SECRET, "x")

        def build = super.itself
      end
      klass = Class.new { def self.build = 1 }
      klass.singleton_class.prepend(tracing)

      expect(described_class.render(klass)).to eq("```ruby\n# Source: (anonymous class)\ndef self.build = 1\n```")
    end

    it "ignores a class's own name override" do
      klass = Class.new do
        def self.name = "Not A Constant"

        def call = :named
      end

      expect(described_class.render(klass))
        .to eq("```ruby\n# Source: (anonymous class)\ndef self.name = \"Not A Constant\"\n\ndef call = :named\n```")
    end

    it "labels singleton methods with a dot" do
      expect(described_class.render(SourcedHelpers::Normalizer.method(:clean)))
        .to start_with("```ruby\n# Source: SourcedHelpers::Normalizer.clean\ndef self.clean(text)\n")
    end

    it "caches rendered source" do
      expect(described_class.render(SourcedParser)).to equal(described_class.render(SourcedParser))
      expect(described_class.render(SourcedParser.method(:build)))
        .to equal(described_class.render(SourcedParser.method(:build)))
    end

    it "raises ConfigurationError for a squished method with no implementation" do
      klass = base_class

      expect { described_class.render(klass.instance_method(:call)) }
        .to raise_error(Squishling::ConfigurationError, /call has no implementation/)
    end
  end
end
