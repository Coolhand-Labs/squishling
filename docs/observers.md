# Observers

An observer wraps every provider request Squishling makes, so another tool can see it while it happens: open a
tracing span, tag the request, set a thread-local. It is the around-style counterpart to [`squawk`](failures.md#observing-every-attempt-squawk),
which reports each attempt only after it is over.

Squishling ships one, for [Coolhand Labs](coolhand.md), and uses it automatically when the `coolhand` gem is configured.
Any object that responds to `around(call)` is an observer:

```ruby
class TracingObserver
  def around(call)
    Tracer.in_span("squishling #{call.label}", attributes: { "model" => call.model, "role" => call.role.to_s }) do
      yield
    end
  end
end

Squishling.configure { |config| config.observer = TracingObserver.new }
```

`around` must yield exactly once. The block makes the request, so the observer runs around it, on the thread that
makes it: for the concurrent samples of the squishsum harnesses, that is a worker thread, so thread-locals set by the
observer are visible to the HTTP call. What `around` returns is ignored. One that never yields, or yields twice,
raises `ConfigurationError`.

## What `yield` returns

The block returns a `Squishling::Observer::Usage`: the request's `input_tokens` and `output_tokens` (nil when the
provider didn't report them) and the `model` that answered. That is enough to meter spend:

```ruby
class SpendObserver
  def around(call)
    usage = yield
    Metrics.increment("squishling.tokens.in", usage.input_tokens.to_i, tags: ["label:#{call.label}"])
    Metrics.increment("squishling.tokens.out", usage.output_tokens.to_i, tags: ["label:#{call.label}"])
  end
end
```

Usage never includes the model's output; Squishling returns the real response to its own caller, whatever `around`
returns. If the request fails, the error is raised through `yield`, so a `begin/ensure` in `around` still runs.

## `config.observer`

| Value | Meaning |
|---|---|
| `nil` (default) | The Coolhand observer when `coolhand` is loaded and configured, otherwise none |
| `:coolhand` | The Coolhand observer, always. Raises `ConfigurationError` if the gem is missing or too old |
| any object responding to `around` | That observer |
| `false` | None, even when Coolhand is configured |

Anything else raises `ConfigurationError` when you assign it.

## The `call`

`around` receives a `Squishling::Observer::Call` (a `Data`) describing the request:

| Field | |
|---|---|
| `label` | `"Class#method"` |
| `purpose` | The purpose text sent as the system prompt (after `purpose` procs and `append_to_purpose` sections are resolved) |
| `handed_off` | `true` when a `squish!` call sent the call to the LLM (typically from a `rescue`), `false` when `squish_when` or a missing implementation did |
| `harness` | The harness type (`:escalation`, `:squishsum`, `:judged_squishsum`, or a [custom one](harnesses.md#custom-harnesses)) |
| `role` | `nil` for an escalation attempt, `:sample` or `:judge`, as in `squawk`'s `metadata` |
| `sample` | `"a"`, `"b"`, ... for a sample, else `nil` |
| `attempt`, `attempts` | This request's 1-based position in the steps it was asked on, and how many there are: the escalation's expanded steps (or, for a custom harness, those passed to `run.escalate`), the sample's stage, or the judge's steps |
| `model`, `provider` | The step's model and provider (`provider` is `nil` unless declared) |
| `request` | `:chat`, or `:judgment` for a System One judge |

It carries metadata only. The method's inputs, its context, and the model's output never reach an observer: it gets
the request's token [`Usage`](#what-yield-returns) back, and `squawk` is the route for output.

## Errors

An observer is your code: an exception it raises propagates unchanged, and is never retried, escalated, or handed to
`squish_fallback`. Squishling maps a failed request onto `LLMError` or `ConfigurationError` inside the block, so `around` sees those and
can rescue them or let them pass. If `around` rescues one and returns normally, Squishling raises it again: an
observer can watch a failure, not swallow it.
