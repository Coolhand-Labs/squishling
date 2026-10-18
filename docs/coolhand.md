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
| Workload | `Class#method` | `Class#method` (its `description` is the method's purpose) |
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
- The purpose text becomes the workload's description in Coolhand. It is already part of every request Coolhand logs.
- `observer = :coolhand` loads the gem when it is assigned, so assign it after `coolhand` is available (the default
  needs no ordering).
