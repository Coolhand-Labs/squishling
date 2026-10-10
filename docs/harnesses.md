# Harnesses: escalation, squishsum, and ensemble

A squished call's **harness** decides how it uses its [escalation](configuration.md#models-and-escalation):

| Harness | What it does | Requests per call |
|---|---|---|
| `:escalation` (default) | Tries each attempt in order until an output passes the schema and `squish_validate`. | 1 or more |
| `:squishsum` | Asks the escalation's **first step** twice, concurrently. Identical outputs are accepted; different ones raise `Squishling::DisagreementError`. | 2 or more |
| `:judged_squishsum` | Like `:squishsum`, but when the two outputs differ, a **judge** picks one or rejects both. | 2 or more, plus 1 or more judge requests when they differ |
| `:ensemble` | Asks the escalation's **first and second steps** once each, concurrently, so two different models are compared. Identical outputs are accepted; different ones raise `DisagreementError`. | 2 or more |
| `:judged_ensemble` | Like `:ensemble`, but when the two outputs differ, a **judge** picks one or rejects both. | 2 or more, plus 1 or more judge requests when they differ |

Use a squishsum harness when a confidently wrong answer costs more than a second request: one sample can make a
mistake, but two independent samples rarely make the same one. Use an [ensemble](#ensembles) when the two samples
should come from different models: a model rarely disagrees with itself at low temperature, but a cheap and a
stronger model often disagree on exactly the cases the cheap one gets confidently wrong.

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
| `type:` | all | `:escalation`, `:squishsum`, `:judged_squishsum`, `:ensemble`, or `:judged_ensemble` (required in the Hash form). |
| `compare:` | squishsum and ensemble ones | `->(a, b, **inputs) { ... }`, evaluated against the instance with the two typed results and the method's inputs. Truthy means the samples agree. Default: the two outputs are exactly equal. |
| `judge:` | judged ones | The judge step (see [The judge](#the-judge)). Default: the escalation's next step after the sampled ones. |
| `judge_instructions:` | judged ones | A String, or a Proc evaluated against the instance, that replaces the [default judge prompt](#the-default-judge-prompt). |

## Samples

Under `:squishsum`, both samples run on the escalation's first step, with its model, provider, and params
(an [ensemble](#ensembles) runs them on its first and second steps):

- **They're independent.** Each sample has its own chat, and the two requests are sent concurrently on separate
  threads. Only the provider requests run on those threads. Parsing, schema validation, `squish_validate`,
  `compare:`, and the judge all run on the calling thread, so your Squishling callbacks never run concurrently.
  RubyLLM instrumentation subscribers (e.g. `ActiveSupport::Notifications` listeners for `chat.ruby_llm`) do see
  each sample's request on its worker thread, outside the Rails executor, so keep them thread-safe.
- **Each one is retried like an escalation step.** A sample with invalid output is re-asked in its own chat, up to
  their step's `attempts:`, while a sample that already passed keeps its result. A failed request gets a fresh
  chat. A sample still failing after its attempts fails the call with `InvalidOutputError` or `LLMError`, as
  usual. Under `:squishsum`, later escalation steps are never used for samples (see [Ensembles](#ensembles)).
- **Agreement is exact by default.** Free-text fields seldom match word for word, so pass `compare:` to decide
  which fields must match:

  ```ruby
  squishling harness: { type: :squishsum, compare: ->(a, b, **) { a.priority == b.priority && a.team == b.team } }
  ```

  When the samples agree, the first one is returned.

## Ensembles

`:ensemble` and `:judged_ensemble` sample two *different* steps instead of one step twice. Sample `a` is the
escalation's first step and sample `b` its second, each with its own model, provider, and params:

```ruby
class TicketTriager
  include Squishling

  squishling escalation: [{ model: "claude-haiku-4-5", attempts: 2 }, "claude-sonnet-5-5", "claude-opus-5-5"],
             harness: :judged_ensemble   # a = Haiku, b = Sonnet, Opus judges when they differ
  # purpose, output_schema, ...
end
```

- A step's `attempts:` are that sample's retries (here Haiku gets two attempts, Sonnet one), exactly as in
  [Samples](#samples). Steps after the second are never sampled.
- Everything else matches squishsum: independence and concurrency, `compare:`, `DisagreementError`, and the
  judge. `DisagreementError#models` names the model behind each sample.
- The judge defaults to the escalation's **third** step. With only two steps, a `:judged_ensemble` needs `judge:`.
  An ensemble with fewer than two steps, or a judged one with neither a third step nor `judge:`, raises
  `ConfigurationError` before any request.
- A global `default_harness = :ensemble` therefore needs every class to declare at least two steps, and a
  `squish!(model: ...)` override (one step) can't be combined with an ensemble harness.
- Steps are told apart by value, so two adjacent steps with the same model, provider, and params count as one step.

## The judge

With a judged harness, two valid samples that disagree go to a judge. The judge picks candidate `a` or `b`,
whose typed result is returned (`squished?` is `true`), or it picks `neither`, which raises
`DisagreementError`.

The judge is:

1. the `judge:` step, if declared: a model name, or a Hash with `model:`, `provider:`, `params:`, and `attempts:`
   (as in an escalation step, without `order:`), plus `type:`; or
2. the escalation's next step after the sampled ones (the second under `:judged_squishsum`, the third under
   `:judged_ensemble`), with its attempts.

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
