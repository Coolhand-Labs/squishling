# frozen_string_literal: true

# Live tests: Squishling scenarios against a small Anthropic model.
# Run: bundle exec ruby examples/anthropic_example.rb [--api-key KEY] [--model MODEL]
# Key: --api-key, else ANTHROPIC_API_KEY, else exits 1.

require_relative "support/live_harness"

LiveHarness.run(
  script: File.basename(__FILE__),
  provider: :anthropic,
  env_var: "ANTHROPIC_API_KEY",
  default_model: "claude-haiku-4-5-20251001",
  params: { temperature: 0 },
  # Anthropic requires temperature 1 whenever extended thinking is on.
  rejected_params: { thinking: { budget: 1024 }, temperature: 0 }
)
