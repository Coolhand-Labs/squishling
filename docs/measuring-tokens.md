# Measuring token spend

A squished path costs tokens on every call. A Ruby path costs engineer time once, plus upkeep. Measuring the
first tells you when the second is worth paying.

## What Squishling gives you

- `result.squished?` says which path served a call, so you can count LLM calls per class.
- The [`squawk` hook](failures.md#observing-every-attempt-squawk) runs after every LLM attempt and receives the
  method (`label`, e.g. `"ShipmentUpdate#call"`), the model and provider, which attempt it was, and the token usage
  RubyLLM reported. That is enough to attribute spend to a squishling method without any other tooling.
- Cost in dollars comes from RubyLLM's model pricing. Multiply the reported tokens by your model's price, or read it
  from RubyLLM directly (see [the instrumenter](#lower-level-rubyllms-instrumenter)).

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
| [OpenTelemetry](#opentelemetry) | Sending traces to Datadog, Langfuse, Arize, Braintrust, LangSmith, or any OTel backend | The OpenTelemetry SDK, an exporter, and one line |
| [LangSmith](#langsmith) | Browsing traces and token usage in LangSmith | Through OpenTelemetry |

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
`config.base_url` at a Coolhand-compatible endpoint of your own.

### Custom: the `squawk` hook

`config.squawk` runs after every LLM attempt, accepted or rejected, and is handed the method's label, the model,
and the token usage RubyLLM reported. A lambda can take just the keywords it needs:

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

### Lower level: RubyLLM's instrumenter

To meter every RubyLLM request in your app, not only Squishling's, use RubyLLM's own instrumentation. It reports a
`usage.ruby_llm` event for each provider request, with `model`, `provider`, `status`, `tokens` (`input`, `output`,
and more) and `cost`. Give it an object that responds to `instrument(name, payload)` and optionally takes a block. In
Rails, `ActiveSupport::Notifications` is used automatically.

```ruby
class TokenMeter
  def instrument(name, payload = {})
    if name == "usage.ruby_llm"
      Rails.logger.info("llm model=#{payload[:model]} workflow=#{payload[:workflow_name]} " \
                        "in=#{payload[:tokens].input} out=#{payload[:tokens].output}")
    end
    block_given? ? yield : nil
  end
end

RubyLLM.configure { |config| config.instrumenter = TokenMeter.new }
```

These events don't know which squishling made the request. To attribute the spend, wrap the call in a RubyLLM
workflow, and every event emitted inside the block carries its name, id and any `metadata:` you pass. (The
`squawk` hook above needs no wrapping.)

```ruby
RubyLLM.workflow("ShipmentUpdate", metadata: { carrier: "acme-freight" }) do
  ShipmentUpdate.call(carrier: "acme-freight", payload: body)
end
```

### OpenTelemetry

RubyLLM 2.1+ ships its own OpenTelemetry tracer. Each request becomes a span with the model, request settings and
token usage (`gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`), following the OpenTelemetry GenAI
conventions. It does not record message text. Your app owns the SDK and exporters.

```ruby
# Gemfile
gem "opentelemetry-sdk"
gem "opentelemetry-exporter-otlp"   # or your backend's exporter

# config/initializers/opentelemetry.rb
OpenTelemetry::SDK.configure        # reads the standard OTEL_* environment variables
RubyLLM::OpenTelemetry.enable       # starts tracing RubyLLM requests
```

Spans don't say which squishling made the request, so pair this with a `RubyLLM.workflow` (see
[above](#lower-level-rubyllms-instrumenter)) or group by model and prompt in your backend.

### LangSmith

LangSmith accepts OpenTelemetry traces, so the OpenTelemetry setup above covers it: point the OTLP exporter at
LangSmith. See LangSmith's
[OpenTelemetry docs](https://docs.smith.langchain.com/observability/how_to_guides/tracing/trace_with_opentelemetry)
for the endpoint and headers. A community Ruby gem, [`langsmith-sdk`](https://github.com/felipekb/langsmith-ruby-sdk),
also exists; it isn't published by LangChain.

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

Check what your tool stores before pointing it at inputs that contain personal data.
