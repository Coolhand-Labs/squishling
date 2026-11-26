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
| `call_id` | The squished call this request belongs to (a UUID, or your own id from [`with_call_id`](#supplying-your-own-call-id) or a [`call_id:` declaration](#declaring-the-call-id), shared by all its requests) |
| `request_id` | This request: `"<call_id>.<n>"`, numbered in the order the call's requests start |
| `apprentice` | `true` for the requests of an [apprentice's](apprentice.md) shadow run, else `false` |

It carries metadata, plus the rendered `purpose`. The method's inputs, its context, and the model's output never reach an
observer: it gets the request's token [`Usage`](#what-yield-returns) back, and `squawk` is the route for output.

## Supplying your own call id

To join Squishling's logs and feedback to your own records, give the call an id of your own:

```ruby
Squishling.with_call_id("ticket-123") { triage.call(ticket) }
```

The first squished call started inside the block uses `"ticket-123"` as its `call_id`, and its requests are
`"ticket-123.1"`, `"ticket-123.2"`, ... Any other squished call in the block (a second one, or one the first makes)
gets its [declared](#declaring-the-call-id) `call_id:` if it has one (then keeping that unique is up to the
declaration), else a generated UUID, so no two requests in the block share an id. The first call keeps the id even when it runs its
Ruby implementation and never reaches the LLM. Across blocks, uniqueness is yours to keep: reusing an id (a job retried
under the same ticket id, say) repeats `request_id`s such as `ticket-123.1`, and Coolhand feedback matched by
`client_unique_id` then becomes ambiguous. The id is a String of 1-250 characters without surrounding
whitespace and without control or invisible (zero-width, bidi, line-separator) characters, or `with_call_id` raises
`ConfigurationError`. A call that fails to bind its arguments doesn't use the id. It is fiber-local, so it applies to calls
made on the block's own fiber, not to those on threads or fibers the block starts (give those their own
`with_call_id`); an [apprentice](apprentice.md) shadow run uses it wherever the run happens.

`with_call_id` yields a handle to the block: `call.call_id` is the id, and `call.accepted_request_id` is the id of the
request whose output the call accepted, once the call has ended. Requests are numbered in the order they start, so after
a retry or an escalation that is `"ticket-123.2"` or higher, not always `.1`; store it if you send feedback later. It is
`nil` when the call only ran Ruby, ended on a `squish_fallback` or an error, or hasn't finished. It covers the call that
took the id (under a sample harness, the request of the sample whose output it returned, the judge's pick for a judged
one), not an apprentice's shadow run (its report's and review's `request_id` name the request that shadow
accepted). A block (or proc) that takes no argument works as before.

### Declaring the call id

If every call has an id of its own, say where it is, instead of wrapping each call site:

```ruby
class RecordTriage
  include Squishling

  squishling model: "claude-haiku-4-5", call_id: :record_id # an input of the method

  def call(record_id:, text:) = ...
end

RecordTriage.call(record_id: "rec-42", text: "...") # call_id "rec-42", requests "rec-42.1", ...
```

`call_id:` takes the name of an input (a Symbol), or a Proc that gets the inputs as keywords and returns the id, such
as `->(ticket:, **) { "ticket-#{ticket.id}" }` (the `**` is for the method's other inputs). Set it on the class or, with `squish :call, call_id: ...`, on one method
(the method's wins; `false` turns off an inherited one; subclasses inherit it). The value is used as text (an Integer or
Symbol is converted), must be a valid id as above, and a `nil` one gives that call a generated UUID. The input
must be a String, Symbol or Integer (anything else raises). It is read when the call reaches the LLM, or when an
apprentice shadows it (its `when:` skipping the call skips this too), so a Ruby-only call never evaluates it. Nested
calls each get their own. An id from `with_call_id` wins for the call it names, and the declaration isn't read for that
call. Declared on a class, it applies to every squished method of the class: a method without the input gets a
generated UUID (a Proc that requires it raises `ArgumentError`), and `Squishling.verify` flags it, so give such a method
its own `call_id:` or `false`. Verify also checks that the Proc takes the inputs.

An id that names an entity (a record id) repeats whenever that entity is processed again, and then so do the request ids.
Squishling logs a warning once per method the first time it sees a declared id twice among that method's last 1,000
ids (naming the method, never the id), since feedback matched by `client_unique_id` can't tell such calls apart. Declare an id unique to each call if you
send feedback by it.

The id reaches observers, `squawk` metadata, apprentice reports and, through the Coolhand observer, Coolhand
(see [Correlating with your own ids](coolhand.md#correlating-with-your-own-ids)). It never goes to the provider. Because it
leaves your process to those tools, don't put personal data in it.

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
