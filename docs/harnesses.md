# Harnesses: escalation, squishsum, and your own

A squished call's **harness** decides how it uses its [escalation](configuration.md#models-and-escalation):

| Harness | What it does | Requests per call |
|---|---|---|
| `:escalation` (default) | Tries each attempt in order until an output passes the schema and `squish_validate`. | 1 or more |
| `:squishsum` | Asks the escalation's **first step** twice, concurrently. Identical outputs are accepted; different ones raise `Squishling::DisagreementError`. | 2 or more |
| `:judged_squishsum` | Like `:squishsum`, but when the two outputs differ, a **judge** picks one or rejects both. | 2 or more, plus 1 or more judge requests when they differ |

Need a different trade-off, such as two models plus a tiebreaker or a majority vote? Register your own with
[`Squishling.register_harness`](#custom-harnesses).

Use a squishsum harness when a confidently wrong answer costs more than a second request: one sample can make a
mistake, but two independent samples rarely make the same one.

```ruby
class TicketTriager
  include Squishling

  squishling escalation: [{ model: "claude-haiku-4-5", attempts: 2 }, "claude-sonnet-5-5"],
             harness: :judged_squishsum   # two Haiku samples; Sonnet judges when they differ
  purpose "Assign a priority and a team."
  output_schema do
    string :priority, enum: %w[low medium high]
    string :team
  end
end
```

## Declaring a harness

`harness:` takes a type, or a Hash with `type:` and its options:

```ruby
Squishling.configure { |c| c.default_harness = :squishsum }      # every class without its own

squishling harness: :judged_squishsum                            # this class (and subclasses)
squish :triage, harness: { type: :squishsum,                     # one method
                           compare: ->(a, b, **) { a.priority == b.priority } }
squish!(harness: :escalation)                                    # one call (see routing.md)
```

The first level that declares one wins: `squish!`, then the method, then the class, then
`Squishling.config.default_harness`, then `:escalation`. Options aren't merged across levels.

| Option | Harnesses | Description |
|---|---|---|
| `type:` | all | `:escalation`, `:squishsum`, `:judged_squishsum`, or a [registered](#custom-harnesses) name (required in the Hash form). |
| `compare:` | squishsum ones | `->(a, b, **inputs) { ... }`, evaluated against the instance with the two typed results and the method's inputs. Truthy means the samples agree. Default: the two outputs are exactly equal. |
| `judge:` | judged ones | The judge step (see [The judge](#the-judge)). Default: the escalation's next step after the sampled one. |
| `judge_instructions:` | judged ones | A String, or a Proc evaluated against the instance, that replaces the [default judge prompt](#the-default-judge-prompt). |

## Samples

Both samples run on the escalation's first step, with its model, provider, and params:

- **They're independent.** Each sample has its own chat, and the two requests are sent concurrently on separate
  threads. Only the provider requests run on those threads. Parsing, schema validation, `squish_validate`,
  `compare:`, and the judge all run on the calling thread, so your Squishling callbacks never run concurrently.
  RubyLLM instrumentation subscribers (e.g. `ActiveSupport::Notifications` listeners for `chat.ruby_llm`) do see
  each sample's request on its worker thread, outside the Rails executor, so keep them thread-safe.
- **Each one is retried like an escalation step.** A sample with invalid output is re-asked in its own chat, up to
  the first step's `attempts:`, while a sample that already passed keeps its result. A failed request gets a fresh
  chat. A sample still failing after its attempts fails the call with `InvalidOutputError` or `LLMError`, as
  usual. Later escalation steps are never used for samples (a judge may use the next one, see
  [The judge](#the-judge)).
- **Agreement is exact by default.** Free-text fields seldom match word for word, so pass `compare:` to decide
  which fields must match:

  ```ruby
  squishling harness: { type: :squishsum, compare: ->(a, b, **) { a.priority == b.priority && a.team == b.team } }
  ```

  When the samples agree, the first one is returned.

## The judge

With a judged harness, two valid samples that disagree go to a judge. The judge picks candidate `a` or `b`,
whose typed result is returned (`squished?` is `true`), or it picks `neither`, which raises
`DisagreementError`.

The judge is:

1. the `judge:` step, if declared: a model name, or a Hash with `model:`, `provider:`, `params:`, and `attempts:`
   (as in an escalation step, without `priority:` or `rotate:`), plus `type:`; or
2. the escalation's next step after the sampled one, with its attempts. Steps tied on `priority:` rotate between calls
   (see [Rotating models](configuration.md#rotating-models-within-a-priority)), so which model that is can vary.

A judged harness with neither raises `ConfigurationError` before any sample is requested. A `judge:`
step uses only its own `provider:`; it doesn't inherit the class or method `provider:`, which belongs to their models
(a chat judge's params, though, do merge over the method's).

### Chat judges

By default the judge is a chat model, asked for a strict `{ "verdict": "a" | "b" | "neither", "reason": "..." }`.
It gets the same context the samples had, plus the samples themselves:

- **System prompt:** the judge prompt, then the operation's own purpose (including any `append_to_purpose`
  sections).
- **User message:** JSON with the samples' `input` (`arguments` and `context`), the `output_schema`, and the
  `candidates` `a` and `b`.

A verdict that doesn't match its schema is retried per the judge step's `attempts:`; a judge that never returns a
valid verdict raises `InvalidOutputError`. A chat judge's params are the method's
[generation params](configuration.md#generation-params) with its own `params:` merged over them.

### System One judgment models (Jev)

A judge can also be a System One decision model, such as TypeSafe's Jev, via
[RubyLLM judgments](https://rubyllm.com/judgments/) (RubyLLM 2.1+). Decision models return calibrated
probabilities rather than text, so they are much faster and cheaper than a chat judge.

```ruby
squishling harness: {
  type: :judged_squishsum,
  judge: { model: "jev-latest", type: :judgment, min_confidence: 0.8 }
}
```

Squishling asks one `choice` question (`a`, `b`, or `neither`), with the judge prompt as its instructions and the
operation's purpose, input, output schema, and candidates as the judgment input. A pick of `a` or `b` is
accepted only when its probability is at least `min_confidence:` (default `0.8`). Otherwise, as with `neither`,
`DisagreementError` is raised with the choice and its probability in its `reason`. A judgment judge sends only its own
`params:` (as RubyLLM `provider_options:`). `attempts:` retries a failed request. Configure the provider's
credentials in RubyLLM as usual.

### The default judge prompt

```text
You are an impartial judge. Two independent attempts at the same operation returned different outputs,
candidate "a" and candidate "b". Both already match the required output format, so judge only their
content. You are given the operation's purpose and its input. Decide which candidate correctly and
faithfully carries out the purpose for this input. If both do (for example, they differ only in
wording), choose either one, preferring "a". Choose "neither" only when both are wrong or you can't tell
whether either is correct. Never combine them or invent a third answer.
```

It is available as `Squishling::Harness::DEFAULT_JUDGE_INSTRUCTIONS`. Replace it with `judge_instructions:`:

```ruby
squishling harness: { type: :judged_squishsum,
                      judge_instructions: "Pick the candidate whose priority follows our SLA rules: ..." }
```

## When the harness fails

A disagreement raises `Squishling::DisagreementError`, a subclass of `InvalidOutputError`. It's raised when the
samples differ with no judge, or when the judge rejects both. Like any failure on the LLM path, it goes to
[`squish_fallback`](failures.md#fallbacks), which can still return one of the candidates:

```ruby
squish_fallback do |error, **|
  raise error unless error.is_a?(Squishling::DisagreementError)

  error.candidates.first   # already typed and validated; squished? is true
end
```

| Attribute | Value |
|---|---|
| `candidates` | The two typed results, `[a, b]` |
| `verdict` | `nil` when there was no judge; `:neither` when the judge rejected both |
| `reason` | The judge's reason (or, for a judgment model, the choice and its probability). A chat judge's reason is model-written, so it is not part of `message` or the logs; a judgment model's choice and probability are |
| `raw` | Both candidates as Hashes, `[a.to_h, b.to_h]` |
| `attempts` | `nil` |
| `models` | The model behind each role: sample `a`, sample `b`, then the judge if one ran (one entry each, not one per attempt) |

Other failures are unchanged. A sample or judge that never produces valid output raises `InvalidOutputError`, a
failed request on the last attempt raises `LLMError`, and setup mistakes (including a provider 400 on either
sample) raise `ConfigurationError`, which is never sent to the fallback.

## Custom harnesses

A harness is a class that decides how to use the escalation: which samples to ask for, how to compare them, who
breaks a tie. Register one under a name and it works anywhere a built-in type does: `squishling harness: :name`,
`squish :method, harness: { type: :name, ... }`, `squish!(harness: ...)`, and `config.default_harness`. It gets
everything the built-ins get: model, provider, and params resolution, schema validation and
[`squish_validate`](failures.md#output-checks-squish_validate), retries and escalation,
[`squawk`](failures.md#observing-every-attempt-squawk) reports with token usage, concurrent samples, and the
[failure behavior](#when-a-custom-harness-fails) (`squish_fallback`, `DisagreementError`).

### Worked example: two models and a tiebreaker

Ask two cheap models. If they agree, done. If they don't, ask a third:

```ruby
class Tiebreaker < Squishling::Harness::Base
  option :tiebreaker, :step, required: true   # a model name, or a step Hash
  option :compare, :proc                      # optional, like squishsum's compare:

  def call(run, tiebreaker:, compare: nil)
    raise Squishling::ConfigurationError, "#{run.label}: needs two models" if run.stages.size < 2

    first, second = run.samples(run.stages.first(2))   # the escalation's first two steps, asked concurrently
    return first if run.agree?(first, second, compare)

    run.escalate(tiebreaker)                           # they differ: a third opinion
  end
end

Squishling.register_harness(:tiebreaker, Tiebreaker)   # e.g. in an initializer

class TicketTriager
  include Squishling

  squishling escalation: ["claude-haiku-4-5", "claude-sonnet-5-5"],
             harness: { type: :tiebreaker, tiebreaker: "claude-opus-5-5",
                        compare: ->(a, b, **) { a.priority == b.priority } }
  purpose "Assign a priority and a team."
  output_schema do
    string :priority, enum: %w[low medium high]
    string :team
  end
end
```

`TicketTriager.call(...)` sends the ticket to Haiku and Sonnet at the same time. A pair that agrees on `priority` returns
Haiku's result; otherwise Opus decides. Either way you get the same typed, validated result as every other path.
`run.stages` groups identical neighbouring steps into one stage (they are one model's attempts), so this harness needs
two different models in the escalation.

For small harnesses, pass a block instead of a class. It becomes the body of a `Squishling::Harness::Base` subclass:

```ruby
Squishling.register_harness(:best_of_three) do
  def call(run)
    results = run.samples([run.stages.first] * 3)
    results.max_by { |result| results.count { |other| run.agree?(result, other) } }   # the most-agreed-with sample
  end
end
```

### Registering

`Squishling.register_harness(name, klass = nil, &block)` takes a `Squishling::Harness::Base` subclass or a block, and
returns the class. `Squishling.harnesses` lists every name, built-ins first.

- The registry is global, and a harness is looked up when it is **declared**, so an unknown name fails up front.
  Register in an initializer, before the classes that use the name load.
- A name is lowercase letters, digits, and underscores. Registering a name twice, or one of `:escalation`,
  `:squishsum`, `:judged_squishsum`, raises `ConfigurationError`.
- A class must define `call` taking the run as its first argument and each declared option as a keyword (a keyword
  for an option that may be left out needs a default), and be creatable without arguments. This is checked at
  registration.
- Subclass `Squishling::Harness::Base` directly. The built-in harness classes are implementation, not an extension
  point; write against `Run` as they do.
- `Squishling.reset_harnesses!` forgets the registered harnesses (the built-ins stay). It is meant for specs.
  `Squishling.reset_config!` leaves them, since they're registered once at boot.

### Options

Declare each option with `option name, type, required: false`, before registering the class. They are checked when
the harness is declared, before any request is made, and an unknown, missing, or mistyped option raises
`ConfigurationError`. A `nil` counts as not given, and `call` receives only the options that were given.

| Type | Accepts | `call` receives |
|---|---|---|
| `:step` | A model name, or a Hash with `model:`, `provider:`, `params:`, `attempts:`, `forward_rejected:` | A normalized, frozen step; pass it to `run.escalate`, or in the Array given to `run.samples` |
| `:proc` | A Proc | The Proc |
| `:string`, `:symbol`, `:integer`, `:boolean` | A String, a Symbol (or String, converted), an Integer, `true` or `false` | The value |

An option with a shape of its own takes a callable as its type instead. It gets the value, the declaration site (a
label for error messages), and the option's name, and returns the normalized value, or raises `ConfigurationError`. The
Hashes, Arrays, and Strings in the result are copied and frozen:

```ruby
option :word, ->(value, label, name) do
  raise Squishling::ConfigurationError, "#{label}: #{name}: must be a String" unless value.is_a?(String)

  value.upcase
end
```

To check options against each other, define `def self.validate_options!(options, label)` and raise
`Squishling::ConfigurationError` (include the `label`) to reject.

### The run

`call(run, **options)` gets a `Squishling::Run`: one squished call, with these primitives. Each returns typed
results, the same type the deterministic path returns.

| Method | What it does |
|---|---|
| `run.receiver`, `run.inputs`, `run.label` | The instance, the method's inputs, and `"Class#method"` |
| `run.steps` | The escalation, one step per attempt |
| `run.stages` | The escalation grouped by model: `[[haiku, haiku], [sonnet]]` for `[{ model: haiku, attempts: 2 }, sonnet]`. A stage is the attempts of one model |
| `run.stage(declaration)` | A stage from a model name or a step Hash (a single step is a stage of one attempt). It keeps its own provider, and its `params:` merge over the method's, as a [judge](#the-judge) step does |
| `run.escalate(*stages)` | Makes each attempt in order until an output passes the schema and `squish_validate`, in the same chat after invalid output and in a fresh one (told about the rejected output) on a new step. With no argument, it runs the escalation: exactly what `:escalation` does |
| `run.samples(stages)` | Takes an Array of stages (so `run.samples([stage, stage])`, not `run.samples(stage)`; a bare step counts as a stage of one attempt): one sample per stage, each in its own chat and retried like an escalation step, with the requests of every round sent concurrently. Returns the outputs in order. Each stage must be one model's attempts: mixed steps raise `ConfigurationError`. Samples are named `"a"`, `"b"`, ... (up to 26) |
| `run.judge(judge: nil, instructions: nil)` | Resolves a [judge](#the-judge) now (so a missing one raises `ConfigurationError` before any request) and returns it. `judge:` is a model name, or a [judge Hash](#the-judge) (`model:`, `provider:`, `params:`, `attempts:`, `type:`, `min_confidence:`; no `priority:` or `rotate:`), and `instructions:` a non-blank String or a Proc. `judge.verdict(first, second)` returns a `Squishling::Judge::Verdict` with `choice` (`:a`, `:b`, or `:neither`), `reason`, and `detail`, and `judge.step` is its first attempt. A chat judge's `reason` is model-written, so use `detail` (Squishling's own text, `nil` for a chat judge), not `reason`, in messages and logs. Without `judge:`, the judge is the escalation's second stage |
| `run.agree?(first, second, compare = nil)` | `compare` (evaluated against the instance with both results and the method's inputs) or, without one, exact equality |
| `run.log(message)` | A warning to `config.logger`, prefixed with `"[Squishling] Class#method"` |

`call` returns the accepted result: one a primitive of this run returned. Returning anything else (a Hash, `nil`, a
result you built or copied with `with`) raises `ConfigurationError`, so a harness can't skip validation.

### When a custom harness fails

A harness fails the way the built-ins do, so `squish_fallback` and the error classes behave predictably:

- **Attempts run out.** `run.escalate` and `run.samples` raise `InvalidOutputError` (invalid output after the last
  attempt) or `LLMError` (a failed request on the last attempt) themselves, with the same attributes as always.
- **Your rule rejects.** Raise one of those errors yourself. `Squishling::DisagreementError.new(candidates:,
  models:)` is the one for samples that don't agree, and `Squishling::InvalidOutputError.new(errors: [...], source: "Harness")` for
  anything else. Both go to [`squish_fallback`](failures.md#fallbacks).
- **Setup mistakes** raise `ConfigurationError`, which is never retried and never sent to the fallback.
- **Your own exceptions** (from `call`, `compare:`, or `squish_validate`) propagate unchanged. Squishling doesn't wrap or
  swallow them.

Keep model output out of the messages you raise and the lines you `run.log`: it can quote the input. The output is
available to your code as the results and in `InvalidOutputError#raw`, and to `squawk` if you opt in.

### Reporting to `squawk`

Every attempt a primitive makes is reported to the [`squawk`](failures.md#observing-every-attempt-squawk) hook, with
usage, so [token measuring](measuring-tokens.md) works unchanged. `metadata[:role]` says what the attempt was for:
`nil` for an escalation attempt, `:sample` (with `metadata[:sample]` set to `"a"`, `"b"`, ...), or `:judge`. `attempt`
and `attempts` count within that sample, judge, or escalation.

### Threads

Only the provider requests inside `run.samples` run on worker threads. Your `call`, parsing, validation,
`squish_validate`, and `compare:` all run on the calling thread, and the routing state stays fiber-local. Call a run's
primitives from the thread `call` runs on: from another one they raise `ConfigurationError`. Don't keep unsynchronized
state at class level in a harness, since one instance is created per call but the class is shared.
