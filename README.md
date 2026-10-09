# Squishling

[![CI](https://github.com/Coolhand-Labs/squishling/actions/workflows/ci.yml/badge.svg)](https://github.com/Coolhand-Labs/squishling/actions/workflows/ci.yml)

Elastic Ruby classes. A squishling class can run as ordinary deterministic Ruby code, **or** bypass its
implementation and send its inputs through an LLM (via [RubyLLM](https://rubyllm.com)), returning a
strict-schema-validated, typed result. Callers can't tell the difference.

Inspired by [Elastic Software](https://everythingengineer.substack.com/p/beginners-write-software-with-ai):
start flexible with AI, then harden high-volume paths into code as the economics justify it.

A squishling needs two things:

1. **Instructions**: the system prompt.
2. **An output schema**: the shape of the result, validated on both paths.

## Installation

```ruby
gem "squishling"
```

Requires Ruby 3.3+ and RubyLLM 2.x. Configure your provider API keys in RubyLLM as usual, then optionally set a
universal model, or an escalation of models to try in order:

```ruby
Squishling.configure do |config|
  config.default_model = "claude-sonnet-5-5" # falls back to RubyLLM's default when nil
  # or: config.default_escalation = [{ model: "claude-haiku-4-5", attempts: 2 }, "claude-sonnet-5-5", "claude-opus-5-5"]
end
```

## Quick start

```ruby
class InvoiceParser
  include Squishling

  instructions "Extract invoice fields from the client's raw data."
  output_schema do
    string :invoice_number
    number :total
  end

  # Clients we've hardened run Ruby; everyone else goes to the LLM.
  squish_when { |client_name:, **| client_name != "acme" }

  def call(client_name:, data:)
    parsed = AcmeParser.parse(data)
    result(invoice_number: parsed.id, total: parsed.sum)
  end
end

r = InvoiceParser.call(client_name: "globex", data: csv)
r.total       # => 1250.0
r.squished?   # => true (came from the LLM)
```

## Features

- **Per-input routing**: a `squish_when` predicate decides Ruby vs. LLM per call, and unimplemented methods
  (`NotImplementedError`) go to the LLM automatically.
- **One contract, two paths**: Ruby returns and LLM output are validated against the same strict schema and
  returned as the same typed `Data` objects.
- **Any RubyLLM provider and model**: OpenAI, Anthropic Claude, Google Gemini, AWS Bedrock, OpenRouter, and more.
  Set a universal model, a per-class model, or a per-method model, plus layered generation params (temperature,
  reasoning effort, top_p, …).
- **Model escalation**: declare an `escalation:` instead of a `model:`, with per-step `attempts:`, `order:`, provider,
  and params. Invalid output (with its errors fed back) or a provider failure moves on to the next attempt. Steps can
  cross providers, e.g. a local Qwen model on Ollama, then Anthropic Claude Haiku on AWS Bedrock, then Claude Opus:

  ```ruby
  RubyLLM.configure do |config|
    config.ollama_api_base = "http://localhost:11434/v1"
    config.bedrock_api_key = ENV["AWS_ACCESS_KEY_ID"]
    config.bedrock_secret_key = ENV["AWS_SECRET_ACCESS_KEY"]
    config.bedrock_region = "us-east-1"
    config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
  end

  class TicketTriager
    include Squishling

    squishling escalation: [
      { model: "qwen3:8b", provider: :ollama, attempts: 2 },   # local and free, tried twice
      { model: "claude-haiku-4-5", provider: :bedrock },       # small hosted model
      { model: "claude-opus-5-5", provider: :anthropic }       # last resort
    ]
    # instructions, output_schema, ...
  end
  ```
- **Output contracts**: beyond the strict schema, conditional rules (`given`) and Ruby checks (`squish_validate`)
  reject bad output and trigger the next attempt.
- **Defined failure behavior**: provider errors become `Squishling::LLMError`, and `squish_fallback` lets you decide
  what to return when every attempt fails.
- **Opt-in context**: only method arguments and the instance state you name with `squish_context` are sent to the
  provider.

## Documentation

- [Configuration](docs/configuration.md): options, models and escalation, providers, generation params, inheritance
- [Routing](docs/routing.md): Ruby vs. LLM, hardening a path, entry points, what the LLM sees
- [Output schemas](docs/schemas.md): schema forms, strict mode, typed results, optional vs. empty, contracts
- [Failure handling](docs/failures.md): escalation, `squish_validate`, error classes, fallbacks
- [Live examples](examples/README.md): end-to-end tests against Anthropic Claude Haiku and OpenAI GPT-6 Luna

## Development

```sh
bin/setup
bundle exec rake        # RSpec (offline; RubyLLM is stubbed) + RuboCop
```

See [AGENTS.md](AGENTS.md) for repo conventions, and [SECURITY.md](SECURITY.md) for reporting vulnerabilities.

## License

Apache-2.0
