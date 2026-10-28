# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.0] - 2026-10-28

### Added

- Pluggable adapters: provider requests go through an adapter (`Squishling::Adapter::Base`, a stateless
  `complete(request)`), set with `config.adapter` or registered with `Squishling.register_adapter`. Two ship:
  `:ruby_llm` (the previous behavior) and `:openai_compatible`, plain `Net::HTTP` against any `/chat/completions`
  endpoint with retries and strict `json_schema` output, which keeps keys and provider text out of errors, logs, and
  `inspect`. See [Adapters](docs/adapters.md). (#47)
- `include_when:` on an escalation step: a Proc called like `squish_when` (the method's inputs as keywords, on the
  instance) that leaves the step out of a call when falsy, for example a model without a BAA. Steps are filtered before
  rotation, and a call left with no steps raises `ConfigurationError`. (#46)
- `squishling/testing` (opt-in, `require "squishling/testing"`): a scripted adapter that records requests and
  conversations, `assert_no_llm_call`/`forbid_provider_calls!`, schema-validated `stub_result`/`stub_error`,
  `validate`/`fallback_for`/`preview`, schema-driven `valid_reply_for`/`invalid_reply_for`, squawk capture, and
  Minitest and RSpec mixins. See [Testing](docs/testing.md). (#44, #50)
- `Squishling.verify`/`verify!` check every squished class without a request (output schema and typed result, resolved
  escalation, params and squawk, harness and judge, the keywords `include_when:`/`squish_when` take, and the adapter),
  reporting every problem; `verify!` raises `VerificationError`. Squished classes are tracked in a weak registry
  (`Squishling.squished_classes`). A `squishling:verify` rake task (with a Rails Railtie) and a `be_squishling_valid`
  RSpec matcher (`require "squishling/rspec"`) wrap it. See [Verifying squished classes](docs/verifying.md). (#48, #67)
- Per-call token budgets: `max_total_output_tokens:` and `max_total_input_tokens:` (on `squishling`, `squish`,
  `squish!`, and `default_max_total_*` in `Squishling.configure`; layered limit by limit, `false` lifts one) cap what one
  call spends across its escalation attempts, squishsum sample rounds, and judge. A request in flight is never cut short,
  so a call can end above the limit by one request. Once a limit is reached the call raises `BudgetExhaustedError`, an
  `InvalidOutputError`, so `squish_fallback` still receives it. (#55, #68)
- `squawk_on:` (`:all`, `:rejections`, `:retries`, `:final`, or a list) filters which attempts reach the `squawk` hook,
  settable with `config.squawk_on`, `squishling squawk_on:`, and `squish :method, squawk_on:`. The default `:all` keeps
  the old behavior. (#58, #69)
- `Adapter::Response#finish_reason` (a Symbol such as `:stop` or `:max_tokens`), filled by both built-in adapters.
  `InvalidOutputError` gains `finish_reason` and `truncated?`, with a fixed note in its message and log line when the
  reply was cut off, and `squawk` metadata gains `finish_reason`. (#54, #60)
- `InvalidOutputError#error_details`: `InvalidOutputError::Detail` entries (`message`, `source` of `:schema`,
  `:validator`, `:parse` or `:squishling`) with a `model_derived?` predicate that is true only for schema errors, which
  can name a key the model chose. Escape just those when forwarding messages to a chat webhook, HTML, or markdown.
  `#errors` is still an Array of Strings (now frozen). (#57, #62)
- `RequestRejectedError` (a `ConfigurationError`) for a provider's 400, with `provider_status` and `provider_code` read
  as plain tokens from the error body (`INVALID_ARGUMENT`, `invalid_request_error`). The provider's message is still
  never repeated. (#52, #53)
- `retry_temperature:` on an escalation step sets the temperature for same-chat retries only. (#56, #61)

### Changed

- **Breaking change:** `ruby_llm` is no longer a runtime dependency of the gem. Apps that use the RubyLLM adapter (the
  default when no adapter is configured and `ruby_llm` is loadable) must now list `gem "ruby_llm"` in their own
  Gemfile, and `require "ruby_llm"` before `RubyLLM.configure` if they don't use `Bundler.require`; or switch to
  `config.adapter = :openai_compatible`. (#47)
- **Behavior change:** a schema property named like a method the typed result needs (`class`, `hash`, `to_h`,
  `members`, `inspect`, `is_a?`, ...) now raises `ConfigurationError` when the schema is built, before any request,
  instead of replacing that method on the result class and failing late. Rename such fields (`class` to
  `ticket_class`); the reserved names are listed in [Output schemas](docs/schemas.md). (#43, #49)
- **Behavior change:** when a same-chat retry returns the exact reply it was just rejected for, Squishling skips the
  step's remaining attempts and moves to the next step (or raises `InvalidOutputError` right away on the last step);
  samples end early the same way. `InvalidOutputError#attempts` counts requests actually made, `squawk` metadata gains
  `repeated:`, and `final:` now means no attempt follows a rejection. Size a step's `attempts:` for replies that can
  differ. (#56, #61)
- A provider 400's "Check params" hint now names a param only when the provider's error body names one you configured,
  and otherwise says the params, output schema, or input may be invalid. An array-wrapped overlong-context 400 from the
  OpenAI-compatible adapter is now an `LLMError`. (#53)

### Fixed

- A raw Hash `output_schema` that omits `type: "object"` no longer lets a non-object reply (a String, Array, or number)
  reach the typed result as a `NoMethodError`; it is now invalid output, retried, escalated, and sent to
  `squish_fallback` like any other. Schemas built with Schematist always had `type: "object"`.
- `RequestRejectedError`'s `provider_status` and `provider_code` no longer accept a hyphenated token, so a key-shaped
  string a gateway echoes into an error body is never repeated in our message. The RubyLLM adapter's "invalid params"
  `ConfigurationError` now names the param keys, not their values.

### Internal

- Development dependencies: `ruby_llm` 2.1.1, `coolhand` 0.10.0, and `rubocop` 1.92.1; CI pins `ruby/setup-ruby` v1.335.0
  so the matrix resolves Ruby 3.3.13, 3.4.12, and 4.0.9. A `finish-release` skill now tags and publishes a reviewed
  release-prep PR. (#45, #51, #59, #63, #64, #65)

## [0.4.0] - 2026-10-18

### Added

- Custom harnesses: `Squishling.register_harness` (with `Squishling.harnesses` and `reset_harnesses!`) and
  `Squishling::Harness::Base` let you write your own harness and use it anywhere a built-in works (`harness:`,
  `squish!`, `default_harness`). A harness gets a `Squishling::Run` with `escalate`, `samples`, `judge`, `agree?`,
  `stage`, and `log`, so it keeps model, provider, and params resolution, `squish_validate`, concurrent samples, and the
  normal failure handling; it can only return typed results its `Run` produced, and its options are validated when it
  is declared. The built-in `:escalation`, `:squishsum`, and `:judged_squishsum` now run on the same interface.
  `squawk` metadata gains `role:` and `sample:`. See [Custom harnesses](docs/harnesses.md#custom-harnesses). (#31)
- Round-robin models: escalation steps that share a `priority:` form a tier. Each call rotates which model in the tier
  goes first (counted per class and method, shared across threads), and the tier's other models are tried before the
  next priority. `rotate: false` on a step pins its tier to the order written. (#38)
- `config.observer`: an around-style hook (`around(call) { ... }`) wrapped around every provider request, on the thread
  that makes it, so a `:squishsum` sample's observer runs on its worker thread. It is told the request's `Observer::Call`
  and gets back only an `Observer::Usage` (token counts and model), never the response. An observer that yields twice
  or never raises `ConfigurationError`, and one that rescues the request's error has it raised again. See
  [Observers](docs/observers.md). (#25, #40)
- A bundled Coolhand observer (`observer = :coolhand`) that declares each call's workload (`Class#method`) and template
  (`squish:L<n>`, `sample:a`, or `judge`) through `Coolhand.with_context`. The workload's description is
  `Class#method`, or `Class#method (rescue)` when a `squish!` call handed the call to the LLM (`Observer::Call#handed_off`),
  never the purpose text. It needs coolhand 0.9.0 or newer. See
  [Coolhand Labs](docs/coolhand.md). (#40)
- A docs page and landing-page section on the architecture, an explainer site in `site/` deployed to GitHub Pages, and
  per-field `description:` documented as the best practice over `purpose` guidance. (#30, #33, #34, #36)

### Changed

- **Behavior change:** when the `coolhand` gem is loaded and configured (an API key, not disabled), Squishling now
  declares each request's workload and template to it automatically. Nothing changes for apps without Coolhand. To
  opt out, set `config.observer = false`.
- **Behavior change:** two escalation steps may now share a `priority:` (they used to raise `duplicate order:`), and
  they rotate per call as described above. If you relied on a fixed order between tied steps, give them distinct
  priorities or set `rotate: false`.
- `order:` on an escalation step is deprecated in favor of `priority:`. It still works, with a deprecation warning, and
  giving both on one step raises `ConfigurationError`. Judge and harness steps take no `priority:` or `rotate:`. (#38)
- **Behavior change:** `LLMError` and the `ConfigurationError` for a rejected request (400), bad credentials, or a
  forbidden key no longer repeat the provider's own message, which can echo request content or part of an API key into
  logs and error trackers. They carry the error class and HTTP status (`RubyLLM::RateLimitError, HTTP 429`); the
  provider's message is still on `cause`. If you matched on provider text in `e.message`, read `e.cause.message`
  instead.
- `docs/measuring-tokens.md` now points to observers for bringing your own metrics instead of walking through a
  hand-rolled one. (#40)

### Removed

- **Breaking change:** the `:ensemble` and `:judged_ensemble` harnesses added in 0.3.0 are gone. `harness: :ensemble`
  or `:judged_ensemble` (and `default_harness`) now raise `ConfigurationError` (unknown harness). Use `:squishsum` or
  `:judged_squishsum`, which sample the first escalation step twice with the judge defaulting to the next step, or
  write a custom harness. (#22, #24)

### Internal

- CI gains an exhale duplication and complexity gate (`bin/exhale`), and dependabot bumps `rubocop` (1.92), `ruby/setup-ruby`,
  and `actions/upload-artifact`. These are development-only changes. (#27, #28, #29, #41)

## [0.3.0] - 2026-10-10

### Added

- Harnesses: a `harness:` option (on `squishling`, `squish`, `squish!`, and `default_harness` in
  `Squishling.configure`) chooses how a call uses its escalation. `:escalation` is the existing behavior and stays
  the default. `:squishsum` asks the first escalation step twice, concurrently, and accepts the result only when the
  two samples agree (exact match, or a custom `compare:`). `:judged_squishsum` sends a disagreement to a judge: the
  next escalation step or a dedicated `judge:` step, either a chat model or a Jev-style decision model through
  `RubyLLM.judge`, with a default prompt you can override through `judge_instructions:`. Samples that still disagree
  raise the new `Squishling::DisagreementError < InvalidOutputError`, which carries both typed results, and
  `squish_fallback` remains the only fallback. See [Harnesses](docs/harnesses.md). (#16)
- `:ensemble` and `:judged_ensemble` harnesses: like the squishsum ones, but the two concurrent samples come from the
  escalation's first and second steps (a cross-model check) instead of the first step twice, each retrying within its
  own step's `attempts:`. A judged ensemble's judge defaults to the third step, or `judge:`, and
  `DisagreementError#models` names the model behind each sample. An ensemble needs at least two distinct steps (adjacent
  identical steps count as one step's attempts) or it raises `ConfigurationError` before any request. (#20)
- `squawk`, an opt-in hook for sending what the model returned to an error tracker or tracing tool. It is called after
  every LLM attempt (every sample and judge attempt under a harness) with `output:`, `metadata:`, and `error:`, and
  can be set on `Squishling.configure`, `squishling`, and `squish`. It does nothing by default, and exceptions it
  raises propagate unchanged. (#15)
- `forward_rejected:` on escalation steps. When an attempt is rejected and the next step starts, the previous
  output is forwarded to that step's provider by default (unchanged behavior); set `forward_rejected: false` to start
  that step from the original input alone. (#14)
- `include Squishling` raises `ConfigurationError` when the class inherits a method Squishling would override (for
  example `Sinatra::Base.call`) instead of silently shadowing it. See [Naming and collisions](docs/naming.md). (#17)

### Documentation

- A new guide, [Measuring token spend](docs/measuring-tokens.md), covers working out what each squished path costs
  (with Coolhand Labs, the `squawk` hook, OpenTelemetry, LangSmith, or RubyLLM's instrumenter), and the README is
  reworked around using Squishling to harden code paths as the economics justify it. (#21)

### Changed

- **Breaking:** the DSL method `instructions` is now `purpose`, and `append_instructions` is now `append_to_purpose`,
  including the `instructions:`/`append_instructions:` keywords on `squishling`, `squish`, and `squish!`. There are no
  aliases. Rename them in your classes: `instructions "..."` becomes `purpose "..."`, and
  `append_instructions: [...]` becomes `append_to_purpose: [...]`. The error for a missing prompt now says
  "has no purpose". (#17)
- **Breaking:** `ruby_llm` must now be `~> 2.1` (was `~> 2.0`); run `bundle update ruby_llm`. (#16)
- **Breaking:** every value a method with an `output_schema` returns is now validated and typed, not only Hashes. On
  the Ruby path and in `squish_fallback`, a `nil`, String, Array, or other non-Hash return that used to pass through
  now raises `InvalidOutputError`; return a Hash (or `result(...)`) that matches the schema. A result of the schema's
  own class passes through, another schema's result is re-validated, and values JSON can't represent (`NaN`,
  `Infinity`, cycles) raise `InvalidOutputError` instead of a raw JSON error. Inner calls (`super`, or the method
  called from `squish_when` or a fallback) still only type Hashes, so overrides can reshape values. (#13)
- **Behavior change:** a provider now travels with the model declared at the same level on a class too. A subclass
  that declares its own `model:` or `escalation:` no longer inherits its parent's `provider:`, which could send the
  whole payload to the parent's provider under another provider's model name. If you relied on that, set `provider:`
  next to the subclass's model.
- **Behavior change:** a `provider:` with no model beside it now raises `ConfigurationError` instead of being
  silently ignored (the default provider was used). `squish ..., provider: ...` needs a `model:` or `escalation:` in
  the same call, as `squish!` already did; `squishling provider: ...` needs one in the call or already declared on that
  class. Move the `provider:` next to a model, or use `config.default_provider` with the default model.
- The `result` alias for `squishling_result` is no longer added when the class already has a `result` (its own or
  inherited); use `squishling_result` there. (#17)
- `InvalidOutputError#message` and `config.logger` warnings no longer quote the model's response. For unparseable JSON
  they report only the line and column; the raw output stays in `InvalidOutputError#raw`. (#15)

### Fixed

- A number a model writes outside the range JSON can represent (such as `1e400`, which parses to `Infinity`), or a
  string with invalid UTF-8, was accepted as valid, while the same value from a Ruby method was rejected. It is now
  invalid output on the LLM path too, and no longer raises a bare `JSON::GeneratorError` when `:squishsum` compares samples.

### Security

- Params can no longer replace the strict output format or tools through the containers that also hold ordinary
  settings: `generationConfig`/`generation_config` (Google Gemini) and `completion_args` (Mistral Conversations) now
  reject their format and tool keys, with symbol or string keys, and a non-Hash value for them is rejected.
  `tool_config` is reserved at the top level. Settings such as `topK` still work. (#12)
- The previous model's rejected output forwarded to the next escalation step is capped at 4,000 characters
  (`Invoker::MAX_FORWARDED_CHARS`), with a truncation marker. (#14)
- Model output is kept out of error messages and logs (see the `InvalidOutputError#message` change above); `squawk`
  is the one sanctioned way for it to leave the process. (#15) A chat judge's `reason` is model-written, so
  `DisagreementError#message` and the logs no longer include it; read it from `DisagreementError#reason`. A
  `:judgment` judge's message still carries the choice and probability, and a choice other than `a`, `b`, or `neither`
  is no longer repeated.
- Only the first 20 validation errors (plus a count of the rest) are fed back to the model, logged, and put in
  `InvalidOutputError#message` for one invalid output, so a very large malformed response can no longer produce a
  megabyte-sized retry message or log line.

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

### Fixed

- A method with an unnamed positional parameter (a destructuring parameter such as `def call((a, b), second)`) sent
  every later argument to the LLM under the wrong name. Each argument now keeps its own name, and unnamed ones are
  sent as `arg0`, `arg1`, and so on.

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
