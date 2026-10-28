# frozen_string_literal: true

require "spec_helper"

RSpec.describe Squishling, ".railtie" do
  it "loads the rake task from the rake_tasks hook" do
    railtie = Class.new { def self.rake_tasks(&block) = (@rake_tasks = block) }
    stub_const("Rails::Railtie", railtie)
    hide_const("Squishling::Railtie")
    load File.expand_path("../../lib/squishling/railtie.rb", __dir__)

    hook = Squishling::Railtie.instance_variable_get(:@rake_tasks)
    expect(Squishling::Railtie).to receive(:load).with(a_string_ending_with("tasks/squishling.rake"))
    Squishling::Railtie.class_eval(&hook)
  end
end
