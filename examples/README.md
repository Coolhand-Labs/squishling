# Examples

Live tests that run Squishling against real provider APIs using small, cheap models. Each script
configures a universal model and runs the same scenarios:

| Scenario | Exercises |
|---|---|
| routing predicate sends unhardened input to the LLM | `squish_when`, DSL schema, nested typed results |
| routing predicate keeps hardened input in Ruby | deterministic path, `result(...)` |
| both paths return the same result class | the elastic contract |
| NotImplementedError falls back to the LLM with squish_context | fallback, `squish`, per-method schema, opt-in context |
| raw JSON Schema hash output | raw strict JSON Schema |

The scripts share `support/live_harness.rb`. Together they make about 8 small requests per provider.

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

A script exits 0 only when every scenario passes. `gpt-6-luna` isn't in RubyLLM's bundled model registry, so
it relies on Squishling's `provider:` support, which tells RubyLLM to assume the model exists.

These examples hit the network and cost real (if tiny) money. They aren't part of `bundle exec rspec`.
