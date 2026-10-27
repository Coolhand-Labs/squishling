# frozen_string_literal: true

module Squishling
  # Adds the squishling:verify rake task to a Rails app (loaded only when Rails is).
  class Railtie < ::Rails::Railtie
    rake_tasks do
      load File.expand_path("tasks/squishling.rake", __dir__)
    end
  end
end
