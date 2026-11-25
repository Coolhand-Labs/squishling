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

The block returns a `Squishling::Observer::Usage`: the request's `input_tokens` and `output_tokens`, the
`cache_read_tokens` and `cache_write_tokens` of [prompt caching](configuration.md#prompt-caching) (each nil when the
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
| `purpose` | The purpose text sent as the system prompt (after `purpose` procs and `append_to_purpose` sections are resolved). It is the whole prompt, including any source you pass to `append_to_purpose` and whatever your `purpose` procs return, so treat it as sensitive: don't log it to a place the prompt itself shouldn't go |
| `handed_off` | `true` when a `squish!` call or a `squish_rescue` sent the call to the LLM, `false` when `squish_when` or a missing implementation did |
| `harness` | The harness type (`:escalation`, `:squishsum`, `:judged_squishsum`, or a [custom one](harnesses.md#custom-harnesses)) |
| `role` | `nil` for an escalation attempt, `:sample` or `:judge`, as in `squawk`'s `metadata` |
| `sample` | `"a"`, `"b"`, ... for a sample, else `nil` |
| `attempt`, `attempts` | This request's 1-based position in the steps it was asked on, and how many there are: the escalation's expanded steps (or, for a custom harness, those passed to `run.escalate`), the sample's stage, or the judge's steps |
| `model`, `provider` | The step's model and provider (`provider` is `nil` unless declared) |
| `adapter` | The name of the [adapter](adapters.md#mixing-adapters-in-one-escalation) the step picked (`nil` for the default one) |
| `request` | `:chat`, or `:judgment` for a System One judge |
| `call_id` | The squished call this request belongs to (a UUID, shared by all its requests) |
| `request_id` | This request: `"<call_id>.<n>"`, numbered in the order the call's requests start |
| `apprentice` | `true` for the requests of an [apprentice's](apprentice.md) shadow run, else `false` |

It carries metadata, plus the rendered `purpose`. The method's inputs, its context, and the model's output never reach an
observer: it gets the request's token [`Usage`](#what-yield-returns) back, and `squawk` is the route for output.

## Apprentice reviews

An observer that also responds to `apprentice(review)` is told how each [apprentice](apprentice.md) shadow run went, after
its report hook. The `Squishling::Apprentice::Review` (a `Data`) has:

- `label`: `"Class#method"`.
- `call_id`: the shadow run's call, `nil` when it ended before it started (`when:` or building the request raised).
- `request_id`: the request whose output was accepted, `nil` when none was.
- `model`.
- `ruby`: the Ruby result, as plain JSON data.
- `match`: `true`, `false`, or `nil` when there was nothing to compare.
- `error`: the class of the error that ended the run, or `nil`. Only the class is passed, because an
  `InvalidOutputError` carries the model's output.

It never carries the model's output. Because it does carry the Ruby result, a reviewing observer sees the method's
output, which a request's `around` never does.

The [Coolhand observer](coolhand.md#apprentice-feedback) uses `apprentice` to send the Ruby result as feedback on the
request.

## Errors

An observer is your code: an exception it raises propagates unchanged, and is never retried, escalated, or handed to
`squish_fallback`. Squishling maps a failed request onto `LLMError` or `ConfigurationError` inside the block, so `around` sees those and
can rescue them or let them pass. If `around` rescues one and returns normally, Squishling raises it again: an
observer can watch a failure, not swallow it.
