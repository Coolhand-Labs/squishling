# frozen_string_literal: true

require "spec_helper"
require "rake"

RSpec.describe Squishling, ".rake_task" do
  let(:rake) { Rake::Application.new }

  before do
    Squishling::ClassRegistry.reset!
    Squishling.config.adapter = FakeAdapter.new
    Rake.application = rake
    load File.expand_path("../../lib/squishling/tasks/squishling.rake", __dir__)
  end

  after { Rake.application = Rake::Application.new }

  it "prints the report and succeeds when the classes are sound" do
    schema = { type: "object", properties: {}, required: [], additionalProperties: false }
    Class.new { include Squishling }.squishling(purpose: "p", output_schema: schema)

    expect { rake["squishling:verify"].invoke }.to output("Squishling: no problems found\n").to_stdout
  end

  it "invokes :environment, defined after the task file loads as Rails does, before verifying" do
    loaded = false
    rake.define_task(Rake::Task, :environment) { loaded = true }

    expect { rake["squishling:verify"].invoke }.to output("Squishling: no problems found\n").to_stdout
    expect(loaded).to be(true)
  end

  it "eager loads a Rails app before verifying" do
    app = double("Rails app", eager_load!: nil) # rubocop:disable RSpec/VerifiedDoubles
    stub_const("Rails", Module.new)
    allow(Rails).to receive(:application).and_return(app)

    expect { rake["squishling:verify"].invoke }.to output(/no problems/).to_stdout
    expect(app).to have_received(:eager_load!)
  end

  it "prints the problems and exits non-zero" do
    Class.new { include Squishling }.squish(:one)

    expect { rake["squishling:verify"].invoke }
      .to output(/Squishling found 2 problems/).to_stdout.and raise_error(SystemExit)
  end
end
