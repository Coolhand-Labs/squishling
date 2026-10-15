# Examples

Live tests that run Squishling against real provider APIs using small, cheap models. Each script
configures a default escalation (its model, with 2 attempts) and runs the same scenarios:

| Scenario | Exercises |
|---|---|
| routing predicate sends unhardened input to the LLM | `squish_when`, DSL schema, nested typed results |
| routing predicate keeps hardened input in Ruby | deterministic path, `result(...)` |
| both paths return the same result class | the elastic contract |
| NotImplementedError falls back to the LLM with squish_context | `NotImplementedError` fallback, `squish`, per-method schema, opt-in context |
| raw JSON Schema hash output | raw strict JSON Schema |
| optional fields keep null (not mentioned) distinct from [] (none) | `optional` (nullable) fields, typed nullable objects |
| conditional (given) rules pass strict mode and are enforced locally | `given` conditionals kept out of the provider's strict schema, validated locally |
| squish_validate rejection escalates to a fresh chat on the next step | `squish_validate`, a two-step `escalation:`, the escalation message |
| squishsum accepts two agreeing samples and squawk reports each attempt | `harness: :squishsum` with a custom `compare:`, two concurrent samples, the `squawk` hook's output, `model`, and `usage` metadata from a real provider |
| ensemble samples the first two escalation steps and accepts them when they agree | `harness: :ensemble` with two steps that differ only in `forward_rejected:`, a custom `compare:` |
| judged_squishsum samples concurrently and a chat judge picks a candidate | `harness:` concurrent samples, `compare:`, a dedicated chat `judge:` |
| params the model rejects raise ConfigurationError, not the fallback | 400 handling, `squish_fallback` bypass |

Every scenario runs with generation params the model supports (`config.default_params`). Each script also
names params its model is known to reject:

| Script | Params used | Params expected to be rejected |
|---|---|---|
| `anthropic_example.rb` | `{ temperature: 0 }` | `{ thinking: { budget: 1024 }, temperature: 0 }` |
| `openai_example.rb` | `{ thinking: { effort: :low } }` | `{ temperature: 0.1 }` (reasoning model) |

The scripts share `support/live_harness.rb`. Together they make about 19 small requests per provider, more if a model needs a retry.

The live scenarios use a chat judge only. A `type: :judgment` judge (a System One decision model such as Jev,
through `RubyLLM.judge`) needs that provider's key and is covered by the offline specs in `spec/harness_spec.rb`.

Failure handling (empty or malformed responses, provider errors, escalation, `squish_fallback`) is covered by the
offline specs in `spec/failure_handling_spec.rb`, `spec/escalation_spec.rb`, and `spec/contracts_spec.rb`, because a
live model can't be made to fail on demand.

## API keys

Each script resolves its key in this order:

1. `--api-key KEY`
2. the provider's env var
3. otherwise it **exits 1**. A missing key is a failure, not a skip.

| Script | Env var | Default model |
|---|---|---|
| `anthropic_example.rb` | `ANTHROPIC_API_KEY` | `claude-haiku-4-5-20251001` |
| `openai_example.rb` | `OPENAI_API_KEY` | `gpt-6-luna` |

## Running

```bash
bundle install
bundle exec ruby examples/anthropic_example.rb
bundle exec ruby examples/openai_example.rb

# Overrides
bundle exec ruby examples/openai_example.rb --model gpt-5.6-luna
bundle exec ruby examples/anthropic_example.rb --api-key "$SOME_OTHER_KEY"
```

A script exits 0 only when every scenario passes. A model missing from RubyLLM's bundled registry (pass one with
`--model`) relies on Squishling's `provider:` support, which tells RubyLLM to assume the model exists.

These examples hit the network and cost real (if tiny) money. They aren't part of `bundle exec rspec`.
