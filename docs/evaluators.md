# Evaluators

An evaluator (an around-hook, not a scorer or judge) wraps every provider request Squishling makes, so another tool can see it while it happens: open a tracing
span, tag the request, set a thread-local. It is the around-style counterpart to [`squawk`](failures.md#observing-every-attempt-squawk),
which reports each attempt only after it is over.

Squishling ships one, for [Coolhand Labs](coolhand.md), and uses it automatically when the `coolhand` gem is configured.
Any object that responds to `around(call)` is an evaluator:

```ruby
class TracingEvaluator
  def around(call)
    Tracer.in_span("squishling #{call.label}", attributes: { "model" => call.model, "role" => call.role.to_s }) do
      yield
    end
  end
end

Squishling.configure { |config| config.evaluator = TracingEvaluator.new }
```

`around` must yield exactly once and return what the block returns (the provider's response). One that never yields
raises `ConfigurationError`; yielding twice sends the request twice. The block makes the
request, so the evaluator runs around it, on the thread that makes it: for the concurrent samples of the squishsum
harnesses, that is a worker thread, so thread-locals set by the evaluator are visible to the HTTP call.

## `config.evaluator`

| Value | Meaning |
|---|---|
| `nil` (default) | The Coolhand evaluator when `coolhand` is loaded and configured, otherwise none |
| `:coolhand` | The Coolhand evaluator, always. Raises `ConfigurationError` if the gem is missing or too old |
| any object responding to `around` | That evaluator |
| `false` | None, even when Coolhand is configured |

Anything else raises `ConfigurationError` when you assign it.

## The `call`

`around` receives a `Squishling::Evaluator::Call` (a `Data`) describing the request:

| Field | |
|---|---|
| `label` | `"Class#method"` |
| `purpose` | The purpose text sent as the system prompt (after `purpose` procs and `append_to_purpose` sections are resolved) |
| `harness` | The harness type (`:escalation`, `:squishsum`, `:judged_squishsum`, or a [custom one](harnesses.md#custom-harnesses)) |
| `role` | `nil` for an escalation attempt, `:sample` or `:judge`, as in `squawk`'s `metadata` |
| `sample` | `"a"`, `"b"`, ... for a sample, else `nil` |
| `attempt`, `attempts` | This request's 1-based position in the steps it was asked on, and how many there are: the escalation's expanded steps (or, for a custom harness, those passed to `run.escalate`), the sample's stage, or the judge's steps |
| `model`, `provider` | The step's model and provider (`provider` is `nil` unless declared) |
| `request` | `:chat`, or `:judgment` for a System One judge |

It carries metadata only. The method's inputs, its context, and the model's output never reach an evaluator; use
`squawk` for output.

## Errors

An evaluator is your code: an exception it raises propagates unchanged, and is never retried, escalated, or handed to
`squish_fallback`. Squishling maps a failed request onto `LLMError` or `ConfigurationError` inside the block, so `around` sees those and
can rescue them or let them pass.
