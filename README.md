# Squishling

[![CI](https://github.com/Coolhand-Labs/squishling/actions/workflows/ci.yml/badge.svg)](https://github.com/Coolhand-Labs/squishling/actions/workflows/ci.yml)

Elastic Ruby classes. A squished method either runs its Ruby implementation or sends its inputs through an LLM
(via [RubyLLM](https://rubyllm.com)), and either way returns the same strict-schema-validated, typed result.
Callers can't tell the difference.

Inspired by [Elastic Software](https://everythingengineer.substack.com/p/beginners-write-software-with-ai):
start flexible with AI, then harden high-volume paths into code as the economics justify it.

## Use cases

### Instant integration

Accept a new data source today, before anyone writes a parser. Declare what you want back and leave the
method unimplemented: every call goes to the LLM, and its output is validated against your schema.

```ruby
class PaymentWebhook
  include Squishling

  instructions "Normalize this payment provider's webhook into our payment event."
  output_schema do
    string  :event, enum: %w[succeeded failed refunded disputed]
    integer :amount_cents
    string  :currency
    string  :external_id
  end
  # No `def call` yet, so every webhook goes to the LLM.
end

event = PaymentWebhook.call(provider: "adyen", payload: request.raw_post)
event.event          # => "refunded"
event.amount_cents   # => 4200
event.squished?      # => true
```

When one provider carries the volume, write `def call` for it and add
`squish_when { |provider:, **| provider != "stripe" }`. Stripe then runs in Ruby, everything else stays on the
LLM, and callers don't change. See [Hardening a path](docs/routing.md#hardening-a-path).

### Error recovery

Keep the Ruby you have for the inputs it understands, and hand the rest to the LLM instead of failing. When the
parser raises, `squish!` sends this call to the LLM with the error and the parser's own source as context.

```ruby
class InvoiceParser
  include Squishling

  instructions "Extract the invoice fields from the vendor's document."
  append_instructions "The Ruby parser that handles well-formed invoices:", self   # this class's source
  output_schema do
    string :invoice_number
    number :total
  end

  def call(vendor:, document:)
    invoice = VendorFormats.fetch(vendor).parse(document)
    result(invoice_number: invoice.number, total: invoice.total)
  rescue VendorFormats::ParseError => e
    squish!(append_instructions: "The parser failed on this document; the error is in the context.",
            context: { parse_error: e })
  end
end

InvoiceParser.call(vendor: "acme", document: pdf_text).squished?    # => false (Ruby parsed it)
InvoiceParser.call(vendor: "acme", document: scanned_text).squished? # => true  (recovered by the LLM)
```

Both calls return the same result class. If the LLM can't deliver either, `squish_fallback` decides what to
return, or the error is raised with the original `ParseError` as its cause. See
[Handing off to the LLM](docs/routing.md#handing-off-to-the-llm-with-squish).

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

## How it works

A squishling class needs **instructions** (the system prompt) and an **output schema** (the shape of the result,
validated on both paths). A squished call goes to the LLM when:

- its `squish_when` predicate is truthy for these inputs,
- the method has no implementation (it isn't defined, or raises `NotImplementedError`), or
- the Ruby implementation calls `squish!`.

Otherwise the Ruby runs, and whatever it returns is validated and typed like LLM output.

## Features

- **One contract, two paths**: Ruby returns and LLM output are validated against the same strict schema and
  returned as the same typed `Data` objects. `squished?` tells you which path served a call.
- **Your code as context**: `append_instructions` adds sections to the prompt, including a class's or method's
  own Ruby source.
- **Any RubyLLM provider and model**: OpenAI, Anthropic Claude, Google Gemini, AWS Bedrock, OpenRouter, and more.
  Set a universal, per-class, per-method, or per-call model, plus layered generation params (temperature,
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
- **Opt-in context**: only method arguments, the instance state you name with `squish_context`, the `context:` you
  pass to `squish!`, and the source you choose to append are sent to the provider.

## Documentation

- [Configuration](docs/configuration.md): options, models and escalation, providers, generation params, inheritance
- [Routing](docs/routing.md): when a call goes to the LLM, `squish!`, `append_instructions`, hardening a path,
  what the LLM sees
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
