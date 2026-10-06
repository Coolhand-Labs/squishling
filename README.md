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

Requires Ruby 3.2+. Configure your provider API keys in RubyLLM as usual, then optionally set a universal model:

```ruby
Squishling.configure do |config|
  config.default_model = "claude-sonnet-5-5" # falls back to RubyLLM's default when nil
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
- **Defined failure behavior**: invalid output is re-asked with the validation errors, provider errors become
  `Squishling::LLMError`, and `squish_fallback` lets you decide what to return when the LLM can't deliver.
- **Opt-in context**: only method arguments and the instance state you name with `squish_context` are sent to the
  provider.

## Documentation

- [Configuration](docs/configuration.md): options, model and provider resolution, generation params, inheritance
- [Routing](docs/routing.md): Ruby vs. LLM, hardening a path, entry points, what the LLM sees
- [Output schemas](docs/schemas.md): schema forms, strict mode, typed results, optional vs. empty
- [Failure handling](docs/failures.md): retries, error classes, fallbacks
- [Live examples](examples/README.md): end-to-end tests against Anthropic Claude Haiku and OpenAI GPT-6 Luna

## Development

```sh
bin/setup
bundle exec rake        # RSpec (offline; RubyLLM is stubbed) + RuboCop
```

See [AGENTS.md](AGENTS.md) for repo conventions, and [SECURITY.md](SECURITY.md) for reporting vulnerabilities.

## License

Apache-2.0
