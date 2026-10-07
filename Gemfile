# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in squishling.gemspec
gemspec

group :development, :test do
  gem "bundler-audit", "~> 0.9", require: false
  gem "simplecov", require: false
  gem "rake", "~> 13.0"
  gem "rspec", "~> 3.13"
  gem "rubocop", "~> 1.62"
  gem "rubocop-performance", "~> 1.23", require: false
  gem "rubocop-rspec", "~> 3.4", require: false

  # No Ruby-version-conditional gems here: the committed Gemfile.lock is installed in frozen
  # mode on every Ruby in the CI matrix, so the Gemfile must resolve identically everywhere.
end
