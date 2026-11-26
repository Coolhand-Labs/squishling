# frozen_string_literal: true

# Outside Rails, load it from your Rakefile: load "squishling/tasks/squishling.rake"
unless Rake::Task.task_defined?("squishling:verify")
  namespace :squishling do
    desc "Verify every squished class without making a request (see Squishling.verify)"
    task :verify do
      # Only loaded classes are known, so load them all first. Rails defines :environment after loading its
      # railties' tasks, so it can't be a prerequisite declared here.
      Rake::Task[:environment].invoke if Rake::Task.task_defined?(:environment)
      Rails.application.eager_load! if defined?(Rails) && Rails.respond_to?(:application) && Rails.application

      report = Squishling.verify
      puts report
      abort unless report.ok?
    end
  end
end
