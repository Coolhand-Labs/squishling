# frozen_string_literal: true

require "spec_helper"

RSpec.describe Squishling::ClassRegistry do
  it "records a class that includes Squishling" do
    klass = squishling_class

    expect(Squishling.squished_classes).to include(klass)
  end

  it "records anonymous classes and subclasses of a squishling class" do
    parent = squishling_class
    child = Class.new(parent)

    expect(parent.name).to be_nil
    expect(Squishling.squished_classes).to include(parent, child)
  end

  it "does not record a class whose include is rejected" do
    rack_app = Class.new { def self.call(env) = env }

    expect { squishling_class(rack_app) }.to raise_error(Squishling::ConfigurationError)
    expect(Squishling.squished_classes.select { |klass| klass < rack_app }).to be_empty
  end

  it "leaves out a named class whose constant now holds a replacement (a code reload)" do
    stub_const("Reloaded", squishling_class)
    original = Reloaded
    stub_const("Reloaded", squishling_class)

    expect(Squishling.squished_classes).to include(Reloaded)
    expect(Squishling.squished_classes).not_to include(original)
  end

  it "leaves out a named class whose constant was removed" do
    stub_const("RemovedSquishling", squishling_class)
    removed = RemovedSquishling
    hide_const("RemovedSquishling")

    expect(Squishling.squished_classes).not_to include(removed)
  end

  it "leaves out a class whose constant is a pending autoload, without loading it" do
    file = File.join(Dir.mktmpdir, "pending_squishling.rb")
    File.write(file, "raise 'autoloaded'")
    stub_const("PendingHolder", Module.new)
    stale = PendingHolder.const_set(:Klass, squishling_class)
    reloaded = Module.new.tap { |holder| holder.autoload(:Klass, file) }
    stub_const("PendingHolder", reloaded)

    expect(Squishling.squished_classes).not_to include(stale)
  end

  it "keeps a class under an anonymous module, whose name can't be looked up" do
    outer = Module.new
    outer.const_set(:Inner, squishling_class)

    expect(Squishling.squished_classes).to include(outer::Inner)
  end

  it "registers from several threads at once" do
    described_class.reset!
    made = Array.new(8) { Thread.new { Array.new(25) { squishling_class } } }.flat_map(&:value)

    expect(Squishling.squished_classes).to match_array(made)
  end

  it "can be reset" do
    squishling_class
    described_class.reset!

    expect(Squishling.squished_classes).to be_empty
  end
end
