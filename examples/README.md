# Examples

Live tests that run Squishling against real provider APIs using small, cheap models. Each provider script
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
| judged_squishsum samples concurrently and a chat judge picks a candidate | `harness:` concurrent samples, `compare:`, a dedicated chat `judge:` |
| params the model rejects raise ConfigurationError, not the fallback | 400 handling, `squish_fallback` bypass |

Every scenario runs with generation params the model supports (`config.default_params`). Each script also
names params its model is known to reject:

| Script | Params used | Params expected to be rejected |
|---|---|---|
| `anthropic_example.rb` | `{ temperature: 0 }` | `{ thinking: { budget: 1024 }, temperature: 0 }` |
| `openai_example.rb` | `{ thinking: { effort: :low } }` | `{ temperature: 0.1 }` (reasoning model) |
| `openai_compatible_example.rb` | `{ thinking: { effort: :low } }` | `{ temperature: 0.1 }` (reasoning model) |

The scripts share `support/live_harness.rb`. `anthropic_example.rb` and `openai_example.rb` go through the RubyLLM
adapter; `openai_compatible_example.rb` runs the same scenarios through the OpenAI-compatible adapter (plain
`Net::HTTP`, no RubyLLM), against OpenAI by default or any endpoint via `--base-url` / `OPENAI_BASE_URL`. Each
script makes about 17 small requests, more if a model needs a retry.

The live scenarios use a chat judge only. A `type: :judgment` judge (a System One decision model such as Jev,
through the RubyLLM adapter's `RubyLLM.judge`) needs that provider's key and is covered by the offline specs in
`spec/harness_spec.rb` and `spec/squishling/adapters/ruby_llm_spec.rb`.

Failure handling (empty or malformed responses, provider errors, escalation, `squish_fallback`) is covered by the
offline specs in `spec/failure_handling_spec.rb`, `spec/escalation_spec.rb`, and `spec/contracts_spec.rb`, because a
live model can't be made to fail on demand.

## Coolhand observer

`coolhand_example.rb` checks Squishling's [Coolhand observer](../docs/coolhand.md) against the real `coolhand` gem
(0.9.0 or newer, the first with `Coolhand.with_context`) and real provider requests. It runs the same small
requests as the scripts above, but Coolhand's log requests go to a throwaway server on `127.0.0.1` instead of
coolhandlabs.com, so no Coolhand account is needed and each scenario can read back exactly what Coolhand received.

| Scenario | Exercises |
|---|---|
| a call is declared to Coolhand with no observer configured | auto-detection: `reporter`, the `Class#method` workload and its purpose, the `squish:L1` template |
| an escalation declares each level as its own template | `squish:L1` and `squish:L2` after a `squish_validate` rejection |
| squishsum declares each sample, from the worker threads that make the requests | `sample:a` and `sample:b`, declared by an observer that runs on the worker threads |
| a judge is declared as its own template | `judge`, alongside both samples |
| observer = false stops declaring, and Coolhand still captures the call | opting out |
| a custom observer gets the request's token usage, and replaces Coolhand's | `Observer::Usage` from a real provider |

It takes `--provider openai` (default) or `--provider anthropic`, plus the usual `--api-key` and `--model`, and makes
about 10 small requests. Like the other scripts, it expects the model to answer validly and the samples to agree, so a
retry or a disagreement reports as a failure.

## API keys

Each script resolves its key in this order:

1. `--api-key KEY`
2. the provider's env var
3. otherwise it **exits 1**. A missing key is a failure, not a skip.

| Script | Env var | Default model |
|---|---|---|
| `anthropic_example.rb` | `ANTHROPIC_API_KEY` | `claude-haiku-4-5-20251001` |
| `openai_example.rb` | `OPENAI_API_KEY` | `gpt-6-luna` |
| `coolhand_example.rb` | `OPENAI_API_KEY`, or `ANTHROPIC_API_KEY` with `--provider anthropic` | `gpt-6-luna`, or `claude-haiku-4-5-20251001` |

## Running

`bin/live-examples` runs every script here concurrently and prints one `PASS` / `NOKEY` / `FAIL` line each, with a
log per script in `tmp/live-examples/`. It exits non-zero unless all pass. Provider keys usually live in `~/.zshrc`,
which a non-interactive shell (an agent's tool shell, say) never sources, so it re-runs itself under `zsh -ic`; set
`SQUISHLING_EXAMPLES_NO_ZSH=1` to use the current environment as-is.

```bash
bin/live-examples
```

Or run one script at a time:

```bash
bundle install
bundle exec ruby examples/anthropic_example.rb
bundle exec ruby examples/openai_example.rb
bundle exec ruby examples/coolhand_example.rb [--provider anthropic]

# Overrides
bundle exec ruby examples/openai_example.rb --model gpt-5.6-luna
bundle exec ruby examples/anthropic_example.rb --api-key "$SOME_OTHER_KEY"
```

A script exits 0 only when every scenario passes. A model missing from RubyLLM's bundled registry (pass one with
`--model`) relies on Squishling's `provider:` support, which tells RubyLLM to assume the model exists.

These examples hit the network and cost real (if tiny) money. They aren't part of `bundle exec rspec`.
