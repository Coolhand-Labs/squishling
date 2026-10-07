# Configuration

Squishling sends requests through [RubyLLM](https://rubyllm.com), so configure provider API keys there first
(OpenAI, Anthropic Claude, Google Gemini, AWS Bedrock, OpenRouter, and any other provider RubyLLM supports):

```ruby
RubyLLM.configure do |config|
  config.anthropic_api_key = ENV.fetch("ANTHROPIC_API_KEY", nil)
  config.openai_api_key = ENV.fetch("OPENAI_API_KEY", nil)
end
```

Then configure Squishling:

```ruby
Squishling.configure do |config|
  config.default_model = "claude-sonnet-5-5"
  config.default_provider = nil
  config.default_params = { temperature: 0 }
  config.max_retries = 1
  config.logger = Rails.logger
end
```

| Option | Default | Description |
|---|---|---|
| `default_model` | `nil` | The universal model for every squishling class that doesn't declare one. `nil` uses RubyLLM's `default_model`. |
| `default_provider` | `nil` | The provider for `default_model`. Only needed for models missing from RubyLLM's registry (see below). |
| `default_params` | `{}` | Generation params for every call (temperature, reasoning effort, top_p, …), overridable per class and per method. See [Generation params](#generation-params). |
| `max_retries` | `1` | How many times to re-ask the LLM after schema-invalid output before raising `InvalidOutputError`. `0` means a single attempt. See [Failure handling](failures.md). |
| `logger` | `nil` | Any `Logger`. Debug lines when a call routes to the LLM, warnings when a fallback is used. |

Transport-level retries (rate limits, 5xx, timeouts) are configured on RubyLLM itself
(`RubyLLM.config.max_retries`, `request_timeout`).

## Model resolution

The model for a squished call comes from the first level that declares one:

1. per call: `squish!(model: "...")` (see [Per-call overrides](#per-call-overrides))
2. per method: `squish :name, model: "..."`
3. per class: `squishling model: "..."` (inherited by subclasses)
4. universal: `Squishling.config.default_model`
5. RubyLLM's `default_model`

```ruby
class InvoiceParser
  include Squishling
  squishling model: "claude-sonnet-5-5"                 # class default

  squish :classify, model: "claude-haiku-4-5" do        # cheaper model for one method
    string :category
  end
end
```

## Providers and newly released models

RubyLLM looks models up in its bundled registry. To use a model that isn't there yet, such as a newly released
OpenAI or Anthropic model, name its provider next to it. Squishling then tells RubyLLM to assume the model exists:

```ruby
squishling model: "gpt-6-luna", provider: :openai
squish :triage, model: "claude-haiku-4-5", provider: :anthropic
Squishling.configure { |c| c.default_model = "gpt-6-luna"; c.default_provider = :openai }
```

A provider is paired with the model declared at the same level, so a per-method model never inherits a
class-level provider meant for a different model. For models that are in the registry, a provider is optional
and the normal registry lookup is kept.

## Generation params

`params` holds generation settings. Set them at any of three levels; each level overrides the one above it
**key by key**:

```ruby
Squishling.configure { |c| c.default_params = { temperature: 0 } }   # every call

class VisitSummarizer
  include Squishling
  squishling params: { temperature: 0.1, top_p: 0.9 }               # this class (and subclasses)

  squish :brainstorm, params: { temperature: 0.9 } do               # one method: temperature 0.9, top_p 0.9
    array :ideas, of: :string
  end
end
```

| Key | Sent as |
|---|---|
| `temperature` | RubyLLM's `with_temperature` |
| `max_output_tokens` | RubyLLM's `with_max_output_tokens` (translated to each provider's own field) |
| `thinking` | RubyLLM's `with_thinking`: `true` (the model's default), `false` (off), or options such as `{ effort: :low }`, `{ budget: 1024 }`, `{ display: :omitted }` |
| anything else (`top_p`, `seed`, `service_tier`, Gemini's `generationConfig`, …) | merged into the provider request as-is via `with_provider_options`, in that provider's own field names |

- **No params means provider defaults.** Squishling sends nothing unless you set it. For structured
  extraction on non-reasoning models (e.g. Anthropic Claude Haiku), a low temperature reduces run-to-run
  variance.
- **Reasoning models** (e.g. OpenAI GPT-6 Luna) usually reject sampling params like `temperature` and `top_p`;
  tune `thinking: { effort: }` instead. Anthropic requires `temperature` to be 1 (or unset) when `thinking` is on.
- **Unsetting an inherited key:** set it to `nil` to send nothing for that key, so the provider default applies.
  This is useful when one method switches to a model that rejects a class-level temperature:

  ```ruby
  squish :triage, model: "gpt-6-luna", provider: :openai, params: { temperature: nil, thinking: { effort: :low } }
  ```

- Keys that Squishling or RubyLLM control (`model`, `messages`, `input`, `instructions`, `system`, `stream`,
  `response_format`, `text`, `output_config`, `tools`, `tool_choice`, `schema`, …) raise `ConfigurationError`,
  because they would override the model, the conversation, or the strict output format.
- If a provider rejects a param, the call raises `Squishling::ConfigurationError` naming the params. It isn't
  retried or sent to `squish_fallback`. See [Failure handling](failures.md).

## Inheritance

Subclasses inherit the model, provider, generation params (merged key by key), instructions, output schema,
`squish_when` predicate, `squish_context` names, `squish_fallback`, and every `squish` declaration. Overrides in a subclass, including
overridden methods, are routed the same way.

`append_instructions` sections are added to, not replaced: a subclass's sections follow its parent's, and
`append_instructions false` drops the inherited ones. See [Appending to the instructions](routing.md#appending-to-the-instructions).

## Per-call overrides

Inside a squished method, `squish!` sends the call to the LLM with its own `instructions:`,
`append_instructions:`, `context:`, `model:`/`provider:`, and `params:`. Each layers over the method and class
settings the same way they layer over each other. See [Escalating from Ruby](routing.md#escalating-from-ruby-with-squish).
