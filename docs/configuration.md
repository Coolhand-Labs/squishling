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
  config.default_model = "claude-sonnet-5-5"   # or default_escalation, below
  config.default_provider = nil
  config.default_params = { temperature: 0 }
  config.default_harness = :escalation
  config.logger = Rails.logger
end
```

| Option | Default | Description |
|---|---|---|
| `default_model` | `nil` | The universal model (a single attempt) for every squishling class that doesn't declare one. `nil` uses RubyLLM's `default_model`. |
| `default_escalation` | `nil` | The universal [escalation](#models-and-escalation): models tried in order. Assigning it clears `default_model`, and vice versa. |
| `default_provider` | `nil` | The provider for `default_model`/`default_escalation` steps that don't name one. Only needed for models missing from RubyLLM's registry (see below). |
| `default_params` | `{}` | Generation params for every call (temperature, reasoning effort, top_p, …), overridable per class, per method, and per escalation step. See [Generation params](#generation-params). |
| `squawk` | `nil` | A callable run after every LLM attempt with the raw output, for sending it to an error tracker or tracing tool. Also settable per class and per method. See [Observing every attempt](failures.md#observing-every-attempt-squawk). |
| `default_harness` | `nil` (`:escalation`) | How every squishling class that doesn't declare its own uses its escalation: `:escalation`, `:squishsum`, `:judged_squishsum`, `:ensemble`, `:judged_ensemble`, or a Hash with `type:` and options. See [Harnesses](harnesses.md). |
| `logger` | `nil` | Any `Logger`. Debug lines when a call routes to the LLM, warnings on each escalation and when a fallback is used. Never includes the raw model response; see [what ends up in errors and logs](failures.md#what-ends-up-in-errors-and-logs). |

Transport-level retries (rate limits, 5xx, timeouts) are configured on RubyLLM itself
(`RubyLLM.config.max_retries`, `request_timeout`).

> **`max_retries` was removed.** The escalation now decides how many attempts run, and setting
> `config.max_retries` raises `ConfigurationError`. The old default (`max_retries = 1`, two attempts on one model) is
> `default_escalation = [{ model: "your-model", attempts: 2 }]`. A plain `model:` now makes one attempt.

## Models and escalation

Declare **either** a `model:`, one model with a single attempt, **or** an `escalation:`, the models to try in
order. When an attempt fails (invalid output, a [`squish_validate`](failures.md#output-checks-squish_validate)
rejection, or a provider failure), the call moves on to the next attempt. It stops at the first valid output, or
raises once the last attempt fails.

```ruby
Squishling.configure do |config|
  config.default_escalation = [
    { model: "claude-haiku-4-5", attempts: 2 },   # attempts 1-2: same conversation, told what was wrong
    "claude-sonnet-5-5",                          # attempt 3: fresh chat, shown Haiku's last output and errors
    "claude-opus-5-5"                             # attempt 4
  ]
end
```

Each step is a model name, or a Hash with:

| Key | Default | Description |
|---|---|---|
| `model:` | required | The model id. |
| `attempts:` | `1` | How many attempts this step gets before escalating to the next one. |
| `order:` | position | An Integer; steps run lowest first. Give every step an `order:` or none (duplicates are rejected). Gaps are fine. |
| `provider:` | the level's `provider:` | See [Providers](#providers-and-newly-released-models). |
| `forward_rejected:` | `true` | Set `false` to start this step from the original input alone, without the previous step's rejected output and its errors (see below). |
| `params:` | `{}` | [Generation params](#generation-params) for this step, merged over the class and method params key by key. |

Without `order:`, steps run in the order written. With it, the order is explicit and doesn't depend on position:

```ruby
squishling escalation: [
  { model: "claude-opus-5-5",   order: 20, params: { thinking: { effort: :high } } },
  { model: "claude-haiku-4-5",  order: 0, attempts: 2 },
  { model: "claude-sonnet-5-5", order: 10 }
]
```

`params:` on a step let one step switch to a reasoning model that rejects sampling params:

```ruby
squishling params: { temperature: 0 },
           escalation: ["gpt-5-mini", { model: "gpt-6-luna", provider: :openai,
                                        params: { temperature: nil, thinking: { effort: :high } } }]
```

### Which model or escalation applies

The first level that declares a `model:` or an `escalation:` supplies the whole thing (levels aren't merged):

1. per call: `squish!(model: ...)` or `squish!(escalation: ...)` (see [Per-call overrides](#per-call-overrides))
2. per method: `squish :name, model: ...` or `escalation: ...`
3. per class: `squishling model: ...` or `escalation: ...` (inherited by subclasses)
4. universal: `Squishling.config.default_model` or `default_escalation`
5. RubyLLM's `default_model` (a single attempt)

```ruby
class InvoiceParser
  include Squishling
  squishling escalation: %w[claude-sonnet-5-5 claude-opus-5-5]   # class escalation

  squish :classify, model: "claude-haiku-4-5" do                 # one cheap attempt for this method
    string :category
  end
end
```

Passing both `model:` and `escalation:` in one declaration raises `ConfigurationError`, and so does a list passed as
`model:`. Across separate declarations (a reopened class, or two config assignments), the latest one wins.

Consecutive attempts of the same step (same model, provider, params, and `forward_rejected:`, e.g. `attempts: 2`)
continue one conversation. Moving to a different step starts a fresh chat with the original input plus the previous
output and why it was rejected, so no provider-specific history crosses providers. That rejected output is
model-generated and is sent to the next step's provider, even when it is a different one, truncated to 4,000
characters. If you don't want a step to see it (say, because the next step is a different provider), set
`forward_rejected: false` on that step and it starts from the original input only. Configuration errors (bad
credentials, an unknown model, a request the provider rejects) never move to the next attempt. See [Failure handling](failures.md).

## Providers and newly released models

RubyLLM looks models up in its bundled registry. To use a model that isn't there yet, such as a newly released
OpenAI or Anthropic model, name its provider next to it. Squishling then tells RubyLLM to assume the model exists:

```ruby
squishling model: "gpt-7-preview", provider: :openai
squish :triage, model: "claude-haiku-4-5", provider: :anthropic
Squishling.configure { |c| c.default_model = "gpt-7-preview"; c.default_provider = :openai }
```

A provider is paired with the model or escalation declared at the same level, and applies to that escalation's steps
that don't name their own. A model never inherits a provider meant for a different model: a per-method model doesn't
take the class's provider, and a subclass that declares its own `model:` or `escalation:` doesn't take its parent's
(a subclass that only changes params or the purpose keeps the parent's model and provider together). For models that
are in the registry, a provider is optional and the normal registry lookup is kept.

A `provider:` with no model beside it would apply to nothing, so it raises `ConfigurationError`:
`squish ..., provider: ...` needs a `model:` or `escalation:` in the same call (as `squish!` always has), and
`squishling provider: ...` needs one in the call or already declared on that same class (not inherited). Set the
provider next to the model, or, for the configured default model, use `config.default_provider`.

## Generation params

`params` holds generation settings. Set them at any of three levels, plus per step in an
[escalation](#models-and-escalation); each level overrides the one above it **key by key**:

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
  `response_format`, `text`, `output_config`, `tools`, `tool_choice`, `schema`, and the camelCase and plural
  spellings other providers use, such as `systemInstruction`, `toolConfig`/`tool_config`, `outputConfig`, `inputs`, …)
  raise `ConfigurationError`, because they would override the model, the conversation, or the strict output format.
- **Nested containers** such as Gemini's `generationConfig` (and `generation_config` for Gemini Interactions) and
  Mistral Conversations' `completion_args` accept ordinary settings, but reject the keys inside them that carry the
  output format or tools (`responseMimeType`, `responseSchema`, `responseJsonSchema`, `response_format`, `tools`,
  `tool_choice`, `toolConfig`, and their snake_case spellings). Use `output_schema` instead:

  ```ruby
  squishling params: { generationConfig: { topK: 5 } }                      # ok
  squishling params: { generationConfig: { responseMimeType: "text/plain" } } # ConfigurationError
  ```

- If a provider rejects a param, the call raises `Squishling::ConfigurationError` naming the params. It isn't
  retried or sent to `squish_fallback`. See [Failure handling](failures.md).

## Inheritance

Subclasses inherit the model or escalation and its provider (as a pair), harness, generation params (merged key by key), purpose, output schema,
`squish_when` predicate, `squish_context` names, `squish_validate`, `squish_fallback`, and every `squish` declaration. Overrides in a subclass, including
overridden methods, are routed the same way.

`append_to_purpose` sections are added to, not replaced: a subclass's sections follow its parent's, and
`append_to_purpose false` drops the inherited ones. See [Appending to the purpose](routing.md#appending-to-the-purpose).

## Per-call overrides

Inside a squished method, `squish!` sends the call to the LLM with its own `purpose:`,
`append_to_purpose:`, `context:`, `model:` or `escalation:` (with `provider:`), `params:`, and `harness:`. Each layers over the method and class
settings the same way they layer over each other. See [Handing off to the LLM](routing.md#handing-off-to-the-llm-with-squish).
