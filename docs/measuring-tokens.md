# Measuring token spend

A squished path costs tokens on every call. A Ruby path costs engineer time once, plus upkeep. Measuring the
first tells you when the second is worth paying.

## What Squishling gives you

- `result.squished?` says which path served a call, so you can count LLM calls per class.
- The [`squawk` hook](failures.md#observing-every-attempt-squawk) runs after every LLM attempt (by default; see `squawk_on` below) and receives the
  method (`label`, e.g. `"ShipmentUpdate#call"`), the model and provider, which attempt it was, and the token usage
  the adapter reported. That is enough to attribute spend to a squishling method without any other tooling.
- Cost in dollars isn't reported by Squishling's adapters. Multiply the reported tokens by your model's price, or, with
  the RubyLLM adapter, read it from RubyLLM directly (see [OpenTelemetry](#opentelemetry), or RubyLLM's `config.instrumenter`).

## Deciding when to write the code

For each squished path, over a month:

```
token cost  =  calls × (input tokens × input price + output tokens × output price)
code cost   =  time to write it  +  upkeep  (new cases, format changes, on-call)
```

Write the Ruby when the token cost keeps exceeding the code cost, and narrow `squish_when` so only the inputs
Ruby can't handle still go to the LLM. See [Hardening a path](routing.md#hardening-a-path). If the token cost
stays small, the debt you haven't taken on is cheaper than the code.

## Tools

| Option | Good for | Setup |
|---|---|---|
| [Coolhand Labs](#coolhand-labs) | Picking up your squishling calls automatically and measuring their cost and accuracy | The `coolhand` gem and an initializer |
| [Custom: the `squawk` hook](#custom-the-squawk-hook) | Logging or metrics in your own stack, with no new dependency | A lambda and one config line |
| [Your own observer](#your-own-observer) | Wrapping each request in your tracing or metrics tool, knowing which method, level, and sample it was | An object with `around(call)` |
| [OpenTelemetry](#opentelemetry) | Sending traces to Datadog, Langfuse, Arize, Braintrust, LangSmith, or any OTel backend | RubyLLM's tracer and an exporter |

### Coolhand Labs

Add and initialize the [`coolhand`](https://github.com/Coolhand-Labs/coolhand-ruby) gem. It intercepts the LLM
requests your app makes, so it picks up your squishling calls automatically and measures their cost, and their
accuracy through Coolhand's feedback tools. No changes to your squishling classes.

```ruby
# Gemfile
gem "coolhand"

# config/initializers/coolhand.rb
Coolhand.configure do |config|
  config.api_key = ENV.fetch("COOLHAND_API_KEY")
end
```

Get an API key at [coolhandlabs.com](https://coolhandlabs.com/). To keep the data in your own infrastructure, point
`config.base_url` at a Coolhand-compatible endpoint of your own. Squishling also tells Coolhand which workload and
template each call belongs to; see [Coolhand Labs](coolhand.md).

### Custom: the `squawk` hook

`config.squawk` runs after every LLM attempt, accepted or rejected (unless you narrow it with `squawk_on:`, which makes token totals undercount, so keep `:all` for measuring), and is handed the method's label, the model,
and the token usage the adapter reported. A lambda can take just the keywords it needs:

```ruby
Squishling.configure do |config|
  config.squawk = lambda do |metadata:, **|
    usage = metadata[:usage] || {}   # nil when the provider call failed; counts it didn't report are absent
    Rails.logger.info("squishling #{metadata[:label]} model=#{metadata[:model]} " \
                      "attempt=#{metadata[:attempt]}/#{metadata[:attempts]} " \
                      "in=#{usage[:input_tokens]} out=#{usage[:output_tokens]}")
  end
end
```

Each line carries the `"Class#method"` that made the call, so grouping by label gives you tokens per squishling. A call
that stays in Ruby makes no LLM request and never reaches the hook, so a label that stops appearing is a path that has
been hardened. You can also set the hook per class (`squishling squawk: ...`) or per method. See
[Observing every attempt](failures.md#observing-every-attempt-squawk) for every keyword and the rules for exceptions.
Under a [harness](harnesses.md), including a [custom one](harnesses.md#custom-harnesses), every sample and judge
request reaches the hook too. `metadata[:role]` (`nil`, `:sample`, or `:judge`) and `metadata[:sample]` (`"a"`, `"b"`, ...)
split the spend by what each request was for.

### Your own observer

An [observer](observers.md) wraps each provider request and gets the request's token usage back from `yield`, so it
can meter spend knowing which method, escalation level, sample, or judge made the request. Any object that responds to
`around(call)` is one:

```ruby
class SpendObserver
  def around(call)
    usage = yield # input_tokens, output_tokens (nil if unreported), and model; never the content
    tags = ["label:#{call.label}", "role:#{call.role || 'squish'}", "model:#{usage.model}"]
    Metrics.increment("squishling.tokens.in", usage.input_tokens.to_i, tags:)
    Metrics.increment("squishling.tokens.out", usage.output_tokens.to_i, tags:)
  end
end

Squishling.configure { |config| config.observer = SpendObserver.new }
```

An observer sees usage, never the model's output or your inputs. See [Observers](observers.md) for the `call` fields
and the rules.

### OpenTelemetry

RubyLLM 2.1+ ships its own OpenTelemetry tracer. Each request becomes a span with the model, request settings and
token usage (`gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`), following the OpenTelemetry GenAI
conventions. It does not record message text. Your app owns the SDK and exporters, and the spans work with any OTLP
backend, [LangSmith](https://docs.smith.langchain.com/observability/how_to_guides/tracing/trace_with_opentelemetry)
included.

```ruby
# Gemfile
gem "opentelemetry-sdk"
gem "opentelemetry-exporter-otlp"   # or your backend's exporter

# config/initializers/opentelemetry.rb
OpenTelemetry::SDK.configure        # reads the standard OTEL_* environment variables
RubyLLM::OpenTelemetry.enable       # starts tracing RubyLLM requests
```

Spans don't say which squishling made the request. To attribute them, wrap the call in `RubyLLM.workflow("Name")`, or
use an [observer](observers.md) that adds the label to the current span. RubyLLM's `config.instrumenter` also reports
a `usage.ruby_llm` event per request, with tokens and cost, if you would rather meter than trace.

## Privacy

Squishling only sends the model what you name: the method arguments, any `squish_context` values, and any source you
append. Tools that sit on the request path are a separate route out of your process, and they see both sides:

- **Request interceptors, such as `coolhand`,** record the prompts (your purpose text and those inputs) and the
  model's responses. Coolhand sends them to coolhandlabs.com unless you point `config.base_url` at an endpoint of your
  own.
- **A `squawk` hook that forwards `output:` or `metadata[:input]`** sends model output and your inputs wherever you
  send them. That is the sanctioned route for model output; see
  [Observing every attempt](failures.md#observing-every-attempt-squawk). The examples above log only metadata.
- **OpenTelemetry** with RubyLLM's tracer records usage and request settings, not message text.
- **An observer** sees timing, token usage, and the call's metadata (method, model, level), never the model's output or
  your inputs.

Check what your tool stores before pointing it at inputs that contain personal data.
