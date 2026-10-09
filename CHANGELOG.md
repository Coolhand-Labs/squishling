# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
