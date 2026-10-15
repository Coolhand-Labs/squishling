# Development Guidelines

Rules for any agent (or human) working in this repo. `CLAUDE.md` imports this file.

## What this gem is

Squishling makes Ruby classes *elastic*: a squished method either runs its Ruby implementation or sends
its inputs through an LLM via [RubyLLM](https://rubyllm.com), returning a strict-schema-validated,
typed result. Both paths must return the same type — that contract is the whole point of the gem.

## Verify before you push

```bash
bundle exec rake    # RSpec (offline, RubyLLM stubbed) + RuboCop — both must pass
```

After the feature or fix is built and `rake` is green, run `/loop-review` until it comes back clean (see
[Review and release skills](#review-and-release-skills)).

Live provider tests are in `examples/` (`bundle exec ruby examples/<provider>_example.rb`). They need real
API keys and cost money, so they run during `/prep-release`, not in CI. Never delete an assertion, mark a
spec pending, or rescue-and-swallow to get green.

## Runtime dependencies

The gem's runtime dependencies are `ruby_llm` (2.1+, for judgments), `schematist` (the schema DSL RubyLLM 2.0 uses),
and `json_schemer`. Keep it that way:

- **Never add a provider SDK** (`openai`, `anthropic`, `google-generativeai`, …). Providers are reached
  through RubyLLM only.
- Development-only gems go in the `Gemfile`'s `:development, :test` group, never the gemspec.
- No Ruby-version-conditional gems in the `Gemfile`: the committed `Gemfile.lock` is installed in frozen
  mode on every Ruby in the CI matrix (3.3–4.0), so it must resolve identically everywhere.
- `examples/`, `spec/`, `bin/`, and agent files are excluded from the packaged gem (see the gemspec).

## Design invariants

Flag any change that breaks one of these; they are behavior contracts, not style:

- **Strict schemas only.** Squishling always requests strict structured output and rejects `strict: false`.
  Every key is required; "not provided" is expressed as a nullable (`optional`) field.
- **Same type from both paths.** Deterministic returns (and fallback returns) are validated against the
  schema and typed exactly like LLM results.
- **Validate everything that comes back.** RubyLLM does not validate structured output and some providers
  don't enforce strict mode; Squishling's own `json_schemer` validation is the guarantee. Conditional keywords
  (`if`/`then`/`else`, `dependentRequired`, `dependentSchemas`) are enforced locally and never sent to the
  provider (`Schema::LOCAL_ONLY_KEYWORDS`).
- **The escalation decides attempts.** A level declares either `model:` (one attempt) or `escalation:` (ordered
  steps with `attempts:`, optionally explicit `order:`); there is no separate retry count, and levels are never merged.
  Invalid output and `LLMError` move on to the next attempt; `ConfigurationError` never does.
- **Error taxonomy.** Everything Squishling raises inherits `Squishling::Error`: `ConfigurationError`
  (setup mistakes; never retried, escalated, or passed to fallbacks), `InvalidOutputError` (bad output after every
  attempt in the escalation),
  `LLMError` (provider/transport failure after RubyLLM's HTTP retries, original as `cause`). Never wrap or
  swallow exceptions raised by the user's own Ruby code.
- **Model output leaves the process only through `InvalidOutputError#raw` and the opt-in `squawk` hook.** Error
  messages and `config.logger` lines carry parse positions and schema paths, never the response itself (the
  documented exceptions are model-chosen extra key names and the developer's own `squish_validate` messages).
- **Only named context leaves the process.** The LLM sees method arguments, `squish_context` values, a
  `squish!` call's `context:`, and source the developer explicitly passes to `append_to_purpose` — never
  instance variables wholesale. Exceptions in context are sent as class and message only. The one model-generated
  exception: escalating to a new step forwards the previous step's rejected output (capped at
  `Invoker::MAX_FORWARDED_CHARS`) to that step's provider, which may differ; a step can opt out with
  `forward_rejected: false`.
- **Params can't override what Squishling owns.** Provider-specific params are merged into the request last
  (RubyLLM's `with_provider_options`), so `Params::RESERVED_KEYS` (model, messages, structured-output format, tools, streaming) stay rejected. A
  provider 400 is a `ConfigurationError`, never something a fallback absorbs.
- **No silent shadowing.** `include Squishling` raises `ConfigurationError` if the class inherits a method it would
  override (`Collisions`), and only adds the `result` alias when the class has no `result`. Classes' own methods win.
- **Thread/fiber safety.** Routing state is fiber-local; shared caches are mutex-guarded. Don't add
  unsynchronized class-level mutable state. The squishsum and ensemble harnesses send their two sample requests on
  worker threads (`LLMClient.concurrently`), and only the requests: parsing, validation, and every Squishling callback
  (`squish_validate`, `compare:`, procs) run on the caller's thread. (RubyLLM instrumentation subscribers fire on
  the worker threads.) Workers must not enter the Rails executor: the caller already holds it, and a second
  interlock share can deadlock against a pending code reload.
- **Harnesses don't add a second rescue path.** Every harness failure surfaces as `InvalidOutputError`
  (disagreements as its `DisagreementError` subclass) or `LLMError`, so `squish_fallback` stays the only fallback.

## Public API

The public surface is `Squishling.configure`/`config`, the `include Squishling` DSL (`squishling` — including its
`model:`/`escalation:` (steps with `model:`, `attempts:`, `order:`, `provider:`, `params:`, `forward_rejected:`)/`provider:`/`params:`/
`harness:` (`type:`, `compare:`, `judge:` (a step, plus `type: :chat | :judgment` and `min_confidence:`),
`judge_instructions:`)/`append_to_purpose:`/`squawk:` options — `purpose`, `append_to_purpose`, `output_schema`,
`squish_when`, `squish_context`, `squish` (including `validate:`/`harness:`/`squawk:`), `squish_validate`,
`squish_fallback`, `result`/`squishling_result`, `squish!` (including `model:`/`escalation:`/`harness:`)),
`Squishling::Configuration` options (including `default_harness`, and `squawk`, whose `output:`/`metadata:`/`error:`
keywords are public), `Squishling::Harness::DEFAULT_JUDGE_INSTRUCTIONS`, result objects (`squished?`,
`to_h`, `[]`), and the error classes (including `InvalidOutputError#models` and
`DisagreementError#candidates`/`verdict`/`reason`). Don't break it without a clear migration path in the changelog.

## Changelog and versioning

Do not add `CHANGELOG.md` entries or bump `lib/squishling/version.rb` on feature/fix branches or in PRs. The
`/prep-release` skill is the sole owner of both — it writes changelog entries for the PRs actually shipping in
a release and bumps the version once, at release time.

Per-PR changelog edits create merge conflicts across concurrent branches for no benefit, since the entries get
rewritten from the final, user-approved set of merged PRs anyway. Leave `CHANGELOG.md` and `version.rb` alone
in your PR.

Releases publish to RubyGems via Trusted Publishing when a `vX.Y.Z` tag is pushed. Agents never create or push
tags, run `rake release`, or `gem push`.

## README and docs philosophy

The README is a landing page — install, quick start, what it supports, where to go next. Keep it scannable.
When in doubt, link rather than expand.

- **Config**: the basic `Squishling.configure` snippet belongs in the README. Model/provider resolution and
  every option go in `docs/configuration.md`.
- **Topics**: anything needing more than one code block gets its own `docs/<topic>.md` (routing, schemas,
  failure handling), linked from the README's Documentation section.
- **Discoverability (SEO / AEO).** Use full provider names ("OpenAI", "Anthropic Claude", "Google Gemini")
  in headings, the gemspec description, and supported-provider lists, so searches for "Ruby LLM structured
  output", "Ruby elastic software", or "RubyLLM schema validation" surface this gem.

## Review and release skills

- `/loop-review` (`.claude/skills/loop-review/SKILL.md`) — iterative review-and-fix of the current diff.
  **Always run it after building a feature or fix, before committing or pushing the branch** — don't wait to be
  asked. Report its result (clean or the remaining findings) along with the work.
- `/prep-release` (`.claude/skills/prep-release/SKILL.md`) — the release event: PR triage, merges,
  changelog/version, security red-team, live examples, release-prep PR.
