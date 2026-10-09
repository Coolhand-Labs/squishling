# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-10-09

### Added

- Model escalation: `escalation:` (and `default_escalation` in `Squishling.configure`) declares an ordered list of
  steps, each a model name or a Hash with `model:`, `attempts:`, an optional explicit `order:`, `provider:`, and
  `params:`. Invalid output or an `LLMError` moves on to the next attempt. Attempts on the same step continue one
  conversation; a new step starts a fresh chat that is told about the rejected output and its errors.
  `ConfigurationError` never escalates. Works per method, per class, in config, and per `squish!` call; the first
  level that declares a model or escalation wins and levels are never merged. `InvalidOutputError#models` lists the
  model tried on each attempt. (#6)
- `squish_validate` (and `validate:` on `squish`): Ruby checks on schema-valid LLM output. Return `nil` or `true` to
  accept, or `false`, a String, an Array of Strings, or a dry-validation style result to reject the output and
  trigger the next attempt. Deterministic and fallback returns are not run through it. (#6)
- Conditional schema rules: Schematist's `given` and `dependent` (JSON Schema `if`/`then`/`else`,
  `dependentRequired`, and `dependentSchemas`) are kept out of the schema sent to the provider, whose strict mode
  doesn't support them, and are still enforced locally on every result. (#6)

### Changed

- **Breaking:** `config.max_retries` is removed; reading or setting it raises `ConfigurationError` with a migration
  hint. The escalation now decides how many attempts run, and a plain `model:` makes a single attempt. To keep the
  old behavior (two attempts on one model), set
  `config.default_escalation = [{ model: "your-model", attempts: 2 }]`. (#6)
- `squish!`'s Ruby-to-LLM handoff is now described as "handing off", so "escalation" only means the model list.
  `squish!` also accepts `escalation:` (instead of `model:`) for one call. (#6)

### Security

- Params can no longer override the system prompt, tool config, or structured-output format through the camelCase
  and plural request keys used by Google Gemini, Amazon Bedrock Converse, and Mistral Conversations
  (`systemInstruction`, `cachedContent`, `toolConfig`, `outputConfig`, `inputs`); these now raise
  `ConfigurationError` like the other reserved keys.

## [0.1.0] - 2026-10-08

Initial release.

### Added

- `include Squishling` DSL that makes a class's methods *elastic*: each call either runs the method's Ruby
  implementation or sends its inputs through an LLM via [RubyLLM](https://rubyllm.com) 2.x, and both paths return
  the same strict-schema-validated, typed result. `squishling`, `instructions`, `output_schema`, `squish_when`,
  `squish_context`, `squish`, `squish_fallback`, and `result` (alias `squishling_result`). (#1)
- Per-input routing: a `squish_when` predicate chooses Ruby or the LLM per call, and a method that is missing or
  raises `NotImplementedError` goes to the LLM automatically. `squish :name, ...` squishes methods other than
  `call`, with per-method `instructions`, `output_schema`, `model`, `provider`, `params`, `when`, and
  `fallback`. (#1)
- Strict output schemas only, from a Schematist DSL block, a `Schematist::Schema` subclass, or a raw JSON Schema
  Hash. Object schemas become `Data` result classes with `squished?`, `to_h`, and `[]`; `optional` expresses "not
  provided" while keeping every key required. `strict: false` raises `ConfigurationError`. (#1)
- Validation of everything that comes back, using `json_schemer`: LLM output, deterministic returns, and fallback
  returns. Invalid LLM output is re-asked with the validation errors, up to `max_retries` (default 1). (#1)
- Failure handling through the `Squishling::Error` taxonomy: `ConfigurationError` (never retried or passed to a
  fallback), `InvalidOutputError` (with `errors`, `raw`, and `attempts`), and `LLMError` (original exception as
  `cause`). `squish_fallback` decides what to return when the LLM can't deliver. Exceptions raised by your own
  Ruby code are never wrapped. (#1)
- `Squishling.configure` with `default_model`, `default_provider`, `default_params`, `max_retries`, and `logger`.
  The model resolves per call, per method, per class, then universally, then RubyLLM's default. Naming a
  `provider:` next to a model lets you use models missing from RubyLLM's registry. (#1)
- Layered generation params (`temperature`, `max_output_tokens`, `thinking`, and any provider-specific key) that
  merge key by key across universal, class, and method levels. Keys that Squishling owns (model, messages,
  structured-output format, tools, streaming) are rejected. (#1)
- Opt-in context: the LLM sees only method arguments and the `squish_context` values you name, never instance
  variables wholesale. Fiber-local routing state and mutex-guarded caches keep it thread- and fiber-safe. (#1)
- `squish!`, which hands the current call to the LLM from inside the Ruby implementation, typically from a
  `rescue`. Optional per-call `context:`, `append_instructions:`, `instructions:`, `model:`, `provider:`, and
  `params:`; the output schema can't be overridden, and a declared `squish_fallback` still applies. Exceptions
  passed in `context:` are sent as their class and message only. (#3)
- `append_instructions`, which adds sections to the system prompt at the class, subclass, `squish` method, or
  per-call level. A section can be a String, a Proc, or a class, module, or method rendered as its Ruby source
  (read with Prism, a Ruby default gem, so there is no new runtime dependency). `false` drops the sections
  declared above it. Appended source is sent to your provider. (#3)
- Live end-to-end examples in `examples/` for Anthropic Claude and OpenAI, including `squish!` scenarios. They need
  real API keys and are not part of the packaged gem. (#1, #3)
- Documentation: configuration, routing, output schemas, and failure handling guides under `docs/`. (#1, #3)
