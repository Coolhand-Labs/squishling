# frozen_string_literal: true

# Live tests: Squishling scenarios through the OpenAI-compatible adapter (plain Net::HTTP, no RubyLLM), against
# OpenAI's own endpoint. Point it at another server with --base-url (Ollama, vLLM, LM Studio, ...).
# Run: bundle exec ruby examples/openai_compatible_example.rb [--api-key KEY] [--model MODEL] [--base-url URL]
# Key: --api-key, else OPENAI_API_KEY, else exits 1.

require_relative "support/live_harness"

base_url = ENV.fetch("OPENAI_BASE_URL", Squishling::Adapters::OpenAICompatible::DEFAULT_BASE_URL)
if (index = ARGV.index("--base-url"))
  ARGV.delete_at(index)
  base_url = ARGV.delete_at(index)
end

LiveHarness.run(
  script: File.basename(__FILE__),
  provider: :openai,
  env_var: "OPENAI_API_KEY",
  default_model: "gpt-6-luna",
  adapter: ->(api_key) { { type: :openai_compatible, base_url:, api_key: } },
  # Reasoning model: tune reasoning effort; sampling params like temperature are rejected.
  params: { thinking: { effort: :low } },
  rejected_params: { temperature: 0.1 }
)
