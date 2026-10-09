# frozen_string_literal: true

require "spec_helper"

RSpec.describe Squishling::Collisions do
  def squishling_class(parent = Object, &body)
    Class.new(parent) do
      include Squishling

      class_eval(&body) if body
    end
  end

  it "raises when a parent class already defines a class method Squishling adds" do
    rack_app = Class.new { def self.call(env) = env }

    expect { squishling_class(rack_app) }
      .to raise_error(Squishling::ConfigurationError, /\.call \(from .*'s class methods\)/)
  end

  it "raises for an inherited purpose DSL method, naming the owner" do
    agent = Class.new { def self.purpose(*) = "agent" }

    expect { squishling_class(agent) }.to raise_error(Squishling::ConfigurationError, /\.purpose \(from /)
  end

  it "raises when a parent class or earlier module defines squish!" do
    parent = Class.new { def squish!(*) = nil }
    mixin = Module.new { def squishling_result(*) = nil }
    host = Class.new { include mixin }

    expect { squishling_class(parent) }.to raise_error(Squishling::ConfigurationError, /#squish! \(from /)
    expect { squishling_class(host) }.to raise_error(Squishling::ConfigurationError, /#squishling_result \(from /)
  end

  it "lists every collision in one error" do
    parent = Class.new do
      def self.call(env) = env
      def squish!(*) = nil
    end

    expect { squishling_class(parent) }.to raise_error(Squishling::ConfigurationError, /\.call .*#squish!/)
  end

  it "does not raise when the class defines the method itself, and its method wins" do
    klass = Class.new do
      def self.call(env) = "mine #{env}"
      include Squishling
    end

    expect(klass.call(1)).to eq("mine 1")
  end

  it "does not raise for a subclass of a class that already includes Squishling" do
    base = squishling_class
    expect { Class.new(base) }.not_to raise_error
    expect { Class.new(base) { include Squishling } }.not_to raise_error
  end

  it "does not raise for a redundant include in a subclass whose parent defines its own class method" do
    parent = Class.new do
      def self.call(env) = "parent #{env}"
      include Squishling
    end
    child = Class.new(parent) { include Squishling }

    expect(child.call(1)).to eq("parent 1")
  end

  it "raises when a module extended onto the class before the include defines a DSL method" do
    mixin = Module.new { def purpose(*) = "mixin" }
    host = Class.new { extend mixin }

    expect { squishling_class(host) }.to raise_error(Squishling::ConfigurationError, /\.purpose \(from #<Module/)
  end

  describe "the result alias" do
    it "is installed on a plain class" do
      expect(squishling_class.new).to respond_to(:result)
    end

    it "leaves an inherited result alone and still provides squishling_result" do
      parent = Class.new { def result = :parents }
      klass = squishling_class(parent)

      expect(klass.new.result).to eq(:parents)
      expect(klass.method_defined?(:squishling_result)).to be(true)
    end

    it "leaves an inherited private result alone" do
      parent = Class.new do
        private

        def result = :private_parents
      end
      klass = squishling_class(parent)

      expect(klass.new.send(:result)).to eq(:private_parents)
      expect(klass.new).not_to respond_to(:result)
    end

    it "works inside a squished method, in a subclass too" do
      base = squishling_class do
        output_schema { string :name }
        squish :call
        def call(name:) = result(name:)
      end
      child = Class.new(base)

      expect(base.new.call(name: "a").name).to eq("a")
      expect(child.new.call(name: "b").name).to eq("b")
    end

    it "leaves a result the class defined before including alone" do
      klass = Class.new do
        def result = :mine
        include Squishling
      end

      expect(klass.new.result).to eq(:mine)
    end
  end
end
