# frozen_string_literal: true

# Live tests: Squishling scenarios against a small OpenAI model.
# Run: bundle exec ruby examples/openai_example.rb [--api-key KEY] [--model MODEL]
# Key: --api-key, else OPENAI_API_KEY, else exits 1.

require_relative "support/live_harness"

LiveHarness.run(
  script: File.basename(__FILE__),
  provider: :openai,
  env_var: "OPENAI_API_KEY",
  default_model: "gpt-6-luna"
)
