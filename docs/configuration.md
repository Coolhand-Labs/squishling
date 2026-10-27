# Configuration

Squishling sends requests through an [adapter](adapters.md): [RubyLLM](https://rubyllm.com) (OpenAI, Anthropic
Claude, Google Gemini, AWS Bedrock, OpenRouter, and any other provider RubyLLM supports), any OpenAI-compatible
endpoint, or your own. With none configured it uses RubyLLM when the `ruby_llm` gem is in your bundle. For RubyLLM,
configure provider API keys there first (`require "ruby_llm"` first if your app doesn't use `Bundler.require`):

```ruby
RubyLLM.configure do |config|
  config.anthropic_api_key = ENV.fetch("ANTHROPIC_API_KEY", nil)
  config.openai_api_key = ENV.fetch("OPENAI_API_KEY", nil)
end
```

Then configure Squishling:

```ruby
Squishling.configure do |config|
  config.adapter = :ruby_llm                   # or :openai_compatible, or your own: see Adapters
  config.default_model = "claude-sonnet-5-5"   # or default_escalation, below
  config.default_provider = nil
  config.default_params = { temperature: 0 }
  config.default_harness = :escalation
  config.logger = Rails.logger
end
```

| Option | Default | Description |
|---|---|---|
| `adapter` | `nil` (RubyLLM, when its gem is available) | How requests reach a model: `:ruby_llm`, `:openai_compatible`, a [registered](adapters.md#writing-your-own) name, a Hash with `type:` and that adapter's options, or an adapter instance. See [Adapters](adapters.md). |
| `default_model` | `nil` | The universal model (a single attempt) for every squishling class that doesn't declare one. `nil` uses the adapter's own default (RubyLLM's `default_model`; the OpenAI-compatible adapter's `default_model:` option). |
| `default_escalation` | `nil` | The universal [escalation](#models-and-escalation): models tried in order. Assigning it clears `default_model`, and vice versa. |
| `default_provider` | `nil` | The provider for `default_model`/`default_escalation` steps that don't name one. What it means depends on the adapter: RubyLLM needs it only for models missing from its registry (see below); the OpenAI-compatible adapter ignores it. |
| `default_params` | `{}` | Generation params for every call (temperature, reasoning effort, top_p, …), overridable per class, per method, and per escalation step. See [Generation params](#generation-params). |
| `default_max_total_output_tokens`, `default_max_total_input_tokens` | `nil` (no limit) | The most output (or input) tokens one call may use across all its requests; once reached, the call raises `BudgetExhaustedError` instead of making another attempt. Overridable per class (`squishling max_total_output_tokens: ...`), per method, and per `squish!` call. See [Capping a call's cost](failures.md#capping-a-calls-cost-token-budgets). |
| `squawk` | `nil` | A callable run after every LLM attempt (see `squawk_on`) with the raw output, for sending it to an error tracker or tracing tool. Also settable per class and per method. See [Observing every attempt](failures.md#observing-every-attempt-squawk). |
| `squawk_on` | `:all` | Which attempts reach the `squawk` hook: `:all`, `:rejections` (errors only), `:retries` (errors plus any accepted attempt after the first), `:final` (the last attempt the escalation allows), or a list of them (any one holding runs the hook). Also settable per class and per method. |
| `observer` | `nil` | An around-style hook for every provider request: `:coolhand`, any object responding to `around(call)`, or `false` for none. `nil` uses the [Coolhand observer](coolhand.md) when the `coolhand` gem is configured. See [Observers](observers.md). |
| `default_harness` | `nil` (`:escalation`) | How every squishling class that doesn't declare its own uses its escalation: `:escalation`, `:squishsum`, `:judged_squishsum`, a [registered custom harness](harnesses.md#custom-harnesses), or a Hash with `type:` and options. See [Harnesses](harnesses.md). |
| `logger` | `nil` | Any `Logger`. Debug lines when a call routes to the LLM, warnings on each escalation and when a fallback is used. Never includes the raw model response; see [what ends up in errors and logs](failures.md#what-ends-up-in-errors-and-logs). |

Transport-level retries (rate limits, 5xx, timeouts) belong to the adapter: RubyLLM's own
(`RubyLLM.config.max_retries`, `request_timeout`), or the OpenAI-compatible adapter's `max_retries:` option.

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
| `priority:` | position | An Integer; steps run lowest first. Give every step a `priority:` or none. Steps with the same priority are one tier (see [Rotating models](#rotating-models-within-a-priority)). Gaps are fine. `order:` is the deprecated name for it. |
| `rotate:` | `true` | Set `false` on a step to keep its tier in the order written instead of rotating it. |
| `include_when:` | always | A Proc that leaves this step out of any call where it returns falsy (see [Excluding a model per call](#excluding-a-model-per-call)). |
| `provider:` | the level's `provider:` | See [Providers](#providers-and-newly-released-models). |
| `retry_temperature:` | none | A Numeric `temperature` for this step's retries in the same chat (not its first attempt), to nudge a model that keeps sending the same rejected reply. Don't use it on a step that sets `thinking`, since reasoning models reject `temperature`. |
| `forward_rejected:` | `true` | Set `false` to start this step from the original input alone, without the previous step's rejected output and its errors (see below). |
| `params:` | `{}` | [Generation params](#generation-params) for this step, merged over the class and method params key by key. |

Without `priority:`, steps run in the order written. With it, the order is explicit and doesn't depend on position:

```ruby
squishling escalation: [
  { model: "claude-opus-5-5",   priority: 30, params: { thinking: { effort: :high } } },
  { model: "claude-haiku-4-5",  priority: 10, attempts: 2 },
  { model: "gemma-4b",          priority: 10 },
  { model: "claude-sonnet-5-5", priority: 20 }
]
```

**Best practice:** number priorities 10, 20, 30, and so on, so a model can be slotted in between later (a `15`)
without renumbering the rest. Haiku and Gemma share the lowest priority here, so they take turns going first (see below).

### Rotating models within a priority

Give several models the same `priority:` and they share a tier. Each call rotates which of them goes first, so
every model gets an even share of the real work over many calls, a fair test of how well each handles it:

```ruby
squishling escalation: [
  { model: "claude-haiku-4-5",  priority: 10 },
  { model: "gemma-4b",          priority: 10 },
  { model: "claude-sonnet-5-5", priority: 20 }
]
# call 1: haiku, gemma-4b, sonnet    call 2: gemma-4b, haiku, sonnet    call 3: haiku, gemma-4b, sonnet
```

- If the model that goes first fails (invalid output or a provider failure, after its own `attempts:`), the other
  models in the tier are tried, in rotated order, before the call escalates to the next priority.
- Each class and method counts its own calls (`AClass#a`, `AClass#b` and `BClass#a` rotate independently), shared across
  threads, but not across processes: each process (a Puma worker, say) starts its own count at the first model, and it
  restarts with the process. A `squish!` whose own escalation has a rotating tier counts against its method too.
- A tier rotates by its declared order, so ties keep the order they were written in. A tier with a single model
  never rotates, and neither does an escalation without `priority:`. `rotate: false` on any step of a tier keeps the
  whole tier in the order written, whatever its other steps say.
- Rotation also moves which stages the [`:squishsum` and `:judged_squishsum`](harnesses.md) harnesses sample first.

### Excluding a model per call

`include_when:` takes a Proc, called like a `squish_when` predicate: against the instance, with the method's inputs as
keywords. A step whose Proc returns falsy is left out of that call's escalation, for example a model without a BAA:

```ruby
squishling escalation: [
  { model: "gpt-5", include_when: ->(client:, **) { !client.needs_a_baa_model? } },
  "claude-sonnet-5-5"
]
```

- Steps are filtered before rotation, so a tier rotates only between the models still eligible for the call. A step
  that is excluded takes no part in its tier, so an excluded `rotate: false` step no longer pins it.
- A call whose steps are all excluded raises `ConfigurationError`. It is never retried or passed to `squish_fallback`.
- It applies wherever an escalation is declared (class, method, `default_escalation`, or `squish!`), but not to a judge
  or harness step, which are single steps.
- The Proc runs on the calling thread. An exception it raises propagates unwrapped.

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
5. the adapter's default model (RubyLLM's `default_model`, or the OpenAI-compatible adapter's `default_model:`; a single attempt)

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

Consecutive attempts of the same step (same model, provider, params, `forward_rejected:`, and `retry_temperature:`, e.g. `attempts: 2`)
continue one conversation. Moving to a different step starts a fresh chat with the original input plus the previous
output and why it was rejected, so no provider-specific history crosses providers. That rejected output is
model-generated and is sent to the next step's provider, even when it is a different one, truncated to 4,000
characters. If you don't want a step to see it (say, because the next step is a different provider), set
`forward_rejected: false` on that step and it starts from the original input only. Configuration errors (bad
credentials, an unknown model, a request the provider rejects) never move to the next attempt. A retry that returns
exactly the reply the step was just told was invalid skips the step's remaining attempts and moves to the next step. See [Failure handling](failures.md).

## Providers and newly released models

This section is about the RubyLLM adapter; the OpenAI-compatible adapter takes model names as given and ignores
`provider:`.

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
| `temperature` | RubyLLM's `with_temperature`; `temperature` in the request body for OpenAI-compatible endpoints |
| `max_output_tokens` | RubyLLM's `with_max_output_tokens` (translated to each provider's own field); `max_completion_tokens` (or `max_tokens`) for OpenAI-compatible endpoints |
| `thinking` | RubyLLM's `with_thinking`: `true` (the model's default), `false` (off), or options such as `{ effort: :low }`, `{ budget: 1024 }`, `{ display: :omitted }`. OpenAI-compatible endpoints take only `{ effort: }`, as `reasoning_effort`. |
| anything else (`top_p`, `seed`, `service_tier`, Gemini's `generationConfig`, …) | merged into the provider request as-is (via `with_provider_options` in RubyLLM), in that provider's own field names |

- **No params means provider defaults.** Squishling sends nothing unless you set it. For structured
  extraction on non-reasoning models (e.g. Anthropic Claude Haiku), a low temperature reduces run-to-run
  variance.
- **Thinking counts against `max_output_tokens`** on providers that bill it as output: leave room for the thinking
  budget plus the answer. With `thinking: { budget: 8192 }` and `max_output_tokens: 8192`, a reply that uses its full
  budget is cut off before any JSON, which shows as [`InvalidOutputError#truncated?`](failures.md#a-cutoff-or-a-wrong-answer).
- **Reasoning models** (e.g. OpenAI GPT-6 Luna) usually reject sampling params like `temperature` and `top_p`;
  tune `thinking: { effort: }` instead. Anthropic requires `temperature` to be 1 (or unset) when `thinking` is on.
- **Unsetting an inherited key:** set it to `nil` to send nothing for that key, so the provider default applies.
  This is useful when one method switches to a model that rejects a class-level temperature:

  ```ruby
  squish :triage, model: "gpt-6-luna", provider: :openai, params: { temperature: nil, thinking: { effort: :low } }
  ```

- Keys that Squishling or the adapter control (`model`, `messages`, `input`, `instructions`, `system`, `stream`,
  `response_format`, `text`, `output_config`, `tools`, `tool_choice`, `functions`, `function_call`, `schema`, and the camelCase and plural
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

Subclasses inherit the model or escalation and its provider (as a pair), harness, generation params (merged key by key), token budgets (limit by limit), purpose, output schema,
`squish_when` predicate, `squish_context` names, `squish_validate`, `squish_fallback`, and every `squish` declaration. Overrides in a subclass, including
overridden methods, are routed the same way.

`append_to_purpose` sections are added to, not replaced: a subclass's sections follow its parent's, and
`append_to_purpose false` drops the inherited ones. See [Appending to the purpose](routing.md#appending-to-the-purpose).

## Per-call overrides

Inside a squished method, `squish!` sends the call to the LLM with its own `purpose:`,
`append_to_purpose:`, `context:`, `model:` or `escalation:` (with `provider:`), `params:`, `harness:`, and
`max_total_output_tokens:`/`max_total_input_tokens:`. Each layers over the method and class
settings the same way they layer over each other. See [Handing off to the LLM](routing.md#handing-off-to-the-llm-with-squish).
