# frozen_string_literal: true

require "spec_helper"
require "squishling/rspec"

RSpec.describe Squishling, "#be_squishling_valid" do
  before do
    Squishling::ClassRegistry.reset!
    Squishling.config.adapter = FakeAdapter.new
  end

  let(:sound) do
    Class.new do
      include Squishling

      squishling purpose: "p"
      squish(:call) { string :a }
    end
  end
  let(:broken) { Class.new { include Squishling }.tap { |klass| klass.squish(:one) } }

  it "passes for a sound class, a list of classes, and Squishling itself" do
    expect(sound).to be_squishling_valid
    expect([sound]).to be_squishling_valid
    expect(Squishling).to be_squishling_valid
  end

  it "fails with the report" do
    broken

    expect { expect(Squishling).to be_squishling_valid }
      .to raise_error(RSpec::Expectations::ExpectationNotMetError, /Squishling found 2 problems/)
    expect(sound).to be_squishling_valid
  end

  it "can be negated" do
    expect(broken).not_to be_squishling_valid
  end
end
