# Apprentice mode: measure the LLM against your Ruby

You have a Ruby implementation you trust, and you want to know how well an LLM would do in its place before you let it
answer a single real call. **Apprentice mode** runs both. The caller always gets the Ruby result, validated and typed as
usual. Alongside it, Squishling sends the same inputs down the LLM path, compares the two typed results, and hands the
comparison to you. Run it on every call or on a sample, and you get a baseline for the model on real traffic.

```ruby
class TicketTriage
  include Squishling

  squishling model: "claude-haiku-4-5",
    apprentice_mode: {
      when: ->(**) { rand < 0.05 },                       # shadow 5% of calls (default: every call)
      report: ->(match:, metadata:, **) { Stats.increment("triage.apprentice", tags: ["match:#{match}"]) }
    }

  purpose "Triage a support ticket."
  output_schema do
    string :priority
    string :team
  end

  def call(ticket_text:)
    # the mature Ruby implementation
  end
end
```

`TicketTriage.call(ticket_text: "...")` returns the Ruby result, as it would without `apprentice_mode:`. On the calls
`when:` picks, the LLM runs as well, and `report:` hears how it did.

## Declaring it

`apprentice_mode:` goes on the class (`squishling apprentice_mode: ...`, inherited by subclasses) or on one method
(`squish :name, apprentice_mode: ...`). It takes:

| Value | Meaning |
|---|---|
| `true` | On, with the defaults: every call, exact comparison, the configured `apprentice_report` |
| a Hash | On, with any of `when:`, `compare:`, `report:` (below) |
| `false` | Off, for a method or subclass that would otherwise inherit it |

A method's Hash is merged over the class's key by key, so a class can set the `report:` and one method its own `when:`.

| Key | Called with | Default |
|---|---|---|
| `when:` | the method's inputs as keywords, evaluated against the instance (like `squish_when`). Truthy runs the LLM alongside. | every call |
| `compare:` | the Ruby result and the LLM's result, then the inputs as keywords, evaluated against the instance (like a harness's `compare:`). Truthy is a match. | the two results hold exactly the same data |
| `report:` | keywords (below); it gets only those it declares, or all with `**`. `false` silences an inherited one. | `config.apprentice_report` |

```ruby
squish :categorize,
  apprentice_mode: { compare: ->(ruby, llm, **) { ruby.category == llm.category } } # ignore the free-text fields
```

The report hook receives:

| Keyword | |
|---|---|
| `ruby:` | The Ruby result (what the caller got) |
| `llm:` | The LLM's typed result, or `nil` when the shadow run failed before producing one |
| `match:` | `true` or `false`, or `nil` when there is nothing to compare (the shadow run failed, or `compare:` raised) |
| `error:` | `nil`, or the error that ended the shadow run |
| `inputs:` | The method's inputs, as a Hash |
| `metadata:` | `label:` (`"Class#method"`), `call_id:` and `request_id:` (see [Identifying the request](#identifying-the-request)), `model:` (that answered), `ruby_seconds:` and `llm_seconds:` (how long each path took) |

To report every apprentice in one place, set the hook once:

```ruby
Squishling.configure do |config|
  config.apprentice_report = ->(ruby:, llm:, match:, error:, metadata:, **) do
    ApprenticeLog.create!(label: metadata[:label], match:, error: error&.class&.name,
      ruby: ruby.to_h, llm: llm&.to_h, request_id: metadata[:request_id])
  end
end
```

## What runs, and what doesn't

The shadow run is the method's normal LLM path: its purpose, `squish_context`, escalation or harness, `squish_validate`,
token budget, `squawk` and observer all apply. Its requests are marked: `squawk` metadata has `apprentice: true`, an
[observer's](observers.md) `call.apprentice` is `true`, and the [Coolhand observer](coolhand.md) describes the
workload as `Class#method (apprentice)`.

It runs only when the Ruby implementation answered the call, which means all of these hold:

- It is the outermost call: not a `super`, and not a call nested inside another call of the same method, so a
  recursive method is shadowed once.
- `squish_when` didn't send the call to the LLM, and the method has an implementation.
- The implementation returned normally (an exception propagates as always, with no shadow run).
- It didn't hand the call over with `squish!`.
- Its return value passed the schema.

## Failures never reach the caller

A shadow run can't change what the caller gets. Whatever ends it goes to the report hook's `error:` and to the logger as a
warning, and is never raised. The log line names an exception from your own code by its class only, because its
message may quote the model's output; the full exception is in `error:`. That covers:

- an `InvalidOutputError` or `LLMError` after the escalation,
- a `BudgetExhaustedError`,
- a `ConfigurationError` such as a missing purpose,
- an exception your own `when:`, `compare:` or `squish_validate` raised.

`squish_fallback` is not used: the caller already has its result, and the report should show what the model did.

The exceptions are what you'd want to hear about at once:

- An exception your report hook (or an observer's `apprentice`) raises propagates on the inline runner, as any of your
  code would. On a background runner there is no caller left to raise to, so it is logged as an error (by class only).
- The errors of [`Squishling::Testing`](testing.md) (an unscripted request in a test) propagate, so a test can't pass
  by accident. On a background runner they are held and raised by the next `Squishling::Apprentice.drain`, which
  `Testing.reset!` calls after each test.

## Running it in the background

By default the shadow run is part of the call: after the Ruby result is ready, the LLM runs on the caller's thread,
and then the call returns. To keep the LLM's latency out of the call, give it a runner:

```ruby
Squishling.configure do |config|
  config.apprentice_runner = :thread                         # the built-in pool
  config.apprentice_runner = Squishling::Apprentice::ThreadRunner.new(size: 4, max_queue: 500)
  config.apprentice_runner = ->(job) { MY_POOL.post(&job) }  # your own: call job, eventually
  config.apprentice_runner = :inline                         # the default
end
```

- **`:thread`** is a `ThreadRunner` with 2 threads and at most 100 pending runs. A run beyond that is dropped and
  logged rather than queued without bound. Threads start on first use and again in each forked worker (Puma, Unicorn).
  Pending runs get 5 seconds to finish when the process exits. In Rails, each run is wrapped in the Rails executor,
  as a background job would be.
- **A callable** gets `job`, a Proc that takes no arguments. Call it on whatever thread you like. It can't be
  serialized into ActiveJob or Sidekiq, because it holds the instance it runs against. If the callable raises (a full
  pool refusing the job), that run is dropped and logged; the call still returns its Ruby result.
- `Squishling::Apprentice.drain(timeout: 5)` waits for the pending runs: in a test, or a shutdown hook. `Testing.reset!`
  calls it for you, and raises `Testing::SetupError` if runs are still pending after 5 seconds.

Whichever runner you use, the request is built on the caller's thread before the call returns. The purpose procs run
there, and the arguments and `squish_context` values are read there, so later changes to the instance aren't sent.
The rest runs in the job, against the same instance: the escalation (with any `include_when:`), `squish_validate`,
`compare:` and the report. Keep those free of state the caller goes on to change, or use the inline runner.

## Identifying the request

Every squished call that reaches the LLM gets a `call_id` (a UUID), and each of its requests a `request_id`
(`"<call_id>.1"`, `".2"`, ... in the order they start). Observers see both on their [`call`](observers.md#the-call), and
`squawk` metadata has the `call_id`. A report's `request_id` names the request whose output was accepted: for an
escalation, the attempt that passed; for a judged squishsum, the sample the judge picked. So the report can be joined
with whatever an observer recorded about that request.

### Coolhand Labs

With the [Coolhand observer](coolhand.md) active, each apprentice result also goes to Coolhand as **feedback** on that
request:

- a match is sent as "like";
- a mismatch as "dislike", with the Ruby result as the revised output.

Over time that gives you the model's agreement rate with your Ruby code, per workload, in Coolhand. It needs coolhand
0.12.0 or later, which tags each log with the request's id (`Coolhand.with_context(client_unique_id:)`), and a Coolhand
server that matches feedback by that id (see [Apprentice feedback](coolhand.md#apprentice-feedback)). With an older gem
the logs carry no id, so no feedback is sent and everything else works as before.

## Turning it off

`config.apprentice_enabled = false` stops every shadow run, whatever the classes declare: a kill switch for an incident,
or for an environment where the LLM shouldn't run. Calls keep returning their Ruby results.

## Testing

A shadow run makes real requests, so a class's existing tests start failing once it declares `apprentice_mode:` (a
forbidden or unscripted request). [`Squishling::Testing`](testing.md#apprentice-mode) turns shadow runs off for the
tests that don't care (`disable_apprentice!`), scripts them separately (`script.apprentice`), and records their reports
(`with_apprentice`):

```ruby
fake_squishling { |script| script.apprentice.reply(priority: "low", team: "api") }
capture = with_apprentice { TicketTriage.call(ticket_text: "Checkout is down") }
capture.reports.first.match # => false
```

[`Squishling.verify`](verifying.md) flags an `apprentice_mode:` declared on a method with no Ruby implementation (a
class's `apprentice_mode:` simply skips its LLM-only methods), and a `when:` or `compare:` that can't take what it is
called with.
