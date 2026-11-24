# Coolhand Labs

Squishling ships an [observer](observers.md) for [Coolhand Labs](https://coolhandlabs.com/). With it, every LLM call a
squished method makes is filed under a named **workload** and **template** in Coolhand. Squishling knows exactly
where each call sits (which method, which escalation level, which sample, which judge), so it declares that for you.

## Setup

Add and configure the [`coolhand`](https://github.com/Coolhand-Labs/coolhand-ruby) gem as described in
[Measuring token spend](measuring-tokens.md#coolhand-labs). **That's all.** Squishling defaults to the Coolhand
observer whenever Coolhand is already available in your codebase: loaded, with an `api_key`, and not disabled
(`config.enabled = false`). Nothing is added to Squishling's dependencies, and nothing happens when the gem isn't
there. It needs a version of the `coolhand` gem that has `Coolhand.with_context` (declared workloads); with an older
one, the observer stays off.

To turn it off, set `observer` to `false`:

```ruby
Squishling.configure do |config|
  config.observer = false # never declare, even though Coolhand is configured
end
```

The other settings:

```ruby
Squishling.configure do |config|
  config.observer = :coolhand # always declare; raises ConfigurationError now if the gem is missing or too old
  config.observer = nil       # the default: declare when Coolhand is loaded and configured
end
```

To report somewhere else, or as well, use any [other observer](observers.md). `config.observer` holds one.

## What is declared

Each request runs inside `Coolhand.with_context(reporter: "squishling", workload: ..., template: ...)`, so Coolhand's
Net::HTTP interception tags it with the declaration.

| | Key | Name |
|---|---|---|
| Workload | `Class#method` | `Class#method` (its `description` is `Class#method`, or `Class#method (rescue)` when a [`squish!`](routing.md#handing-off-to-the-llm-with-squish) call handed it to the LLM) |
| Template | `Class#method/<role>` | `Class#method · <role>` |

`<role>` is where the request sits:

| Role | Request |
|---|---|
| `squish:L<n>` | Attempt *n* (1-based) of the [escalation](configuration.md#models-and-escalation), counting each attempt of each step (a [custom harness](harnesses.md#custom-harnesses) that escalates stage by stage restarts at L1 for each) |
| `sample:a`, `sample:b`, ... | A [squishsum](harnesses.md) sample (which runs on a worker thread; the declaration is made on that thread) |
| `judge` | A harness's judge, chat or System One (all of a judge's attempts share this one template) |

So `Parser#call/squish:L2` is the second attempt of `Parser#call`, e.g. `Parser#call · squish L2` in Coolhand.

- The model is deliberately not in the key. It is on the log, and the position is the stable identity.
- Repeated attempts on the same step count as separate levels, because the level is the attempt's position in the
  expanded escalation.
- A class name long enough to push a key past Coolhand's 255-character limit is left undeclared rather than
  breaking the call.
- Squishling's declaration is made inside any `Coolhand.with_context` you wrapped around the call, so for the fields it
  sets, Squishling's wins.
- The description never contains the purpose text, which can be a proc that differs per call. The workload's key
  and name stay `Class#method` either way, so calls that went through `squish!` and calls that didn't share one
  workload.
- With coolhand 0.12.0 or later (whose `Coolhand.with_context` takes `client_unique_id:`), each request is also tagged
  with its [`request_id`](observers.md#the-call), so feedback can name it (see below).
- `observer = :coolhand` loads the gem when it is assigned, so assign it after `coolhand` is available (the default
  needs no ordering).

## Correlating with your own ids

Give a call your own id (with `with_call_id`, or a [`call_id:` declaration](observers.md#declaring-the-call-id)), and Coolhand's `client_unique_id` for its requests is built from it (`"<id>.1"`, `"<id>.2"`, ...),
so you can send feedback against a request without storing Squishling's UUID:

```ruby
Squishling.with_call_id("ticket-123") { triage.call(ticket) }

Coolhand.flush # logs are sent in the background; make sure this one has been delivered
Coolhand.feedback_service.create_feedback(client_unique_id: "ticket-123.1", sentiment: "like")
```

It needs coolhand 0.12.0 or later, and the id and reuse rules in [Observers](observers.md#supplying-your-own-call-id).

## Apprentice feedback

With [apprentice mode](apprentice.md), every shadow run also becomes feedback in Coolhand on the request whose output was
accepted:

| Outcome | Feedback |
|---|---|
| The LLM matched the Ruby result | `sentiment: "like"` |
| It differed | `sentiment: "dislike"`, with the Ruby result (JSON) as `revised_output` |
| The shadow run failed, or `compare:` raised | none |

The feedback finds its log by `client_unique_id`, the request's `request_id`. So it needs:

- **coolhand 0.12.0 or later**, which tags each log with that id (`Coolhand.with_context(client_unique_id:)`).
  Squishling checks for it: with an older gem, no feedback is sent and everything else works as before.
- **A Coolhand server that stores `client_unique_id` on logs and matches feedback by it**, which Coolhand added
  alongside coolhand 0.12.0.

Squishling doesn't depend on the coolhand gem; add `gem "coolhand", ">= 0.12"` to your own Gemfile. The feedback is
sent from the shadow run's job as soon as the run ends. Coolhand sends its logs from a background queue, so the
feedback can reach Coolhand before the log it names; whether it is still attached then is up to the Coolhand server,
which matches the two by `client_unique_id`. With a [background runner](apprentice.md#running-it-in-the-background),
sending it adds nothing to the call's latency. Each apprentice request's workload is described as
`Class#method (apprentice)`, under the same workload and template keys as the method's other calls.
