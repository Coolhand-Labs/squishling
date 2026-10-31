# Development Guidelines

Rules for any agent (or human) working in this repo. `CLAUDE.md` imports this file.

## What this gem is

Squishling makes Ruby classes *elastic*: a squished method either runs its Ruby implementation or sends
its inputs through an LLM (through an adapter: [RubyLLM](https://rubyllm.com), any OpenAI-compatible endpoint, or your
own), returning a strict-schema-validated,
typed result. Both paths must return the same type — that contract is the whole point of the gem.

## Verify before you push

```bash
bundle exec rake    # RSpec (offline, adapters faked or stubbed) + RuboCop — both must pass
```

CI also runs [exhale](https://github.com/tools4imps/exhale-ruby) (duplication and complexity gate, whole-codebase
sweep). Run it locally with `bin/exhale dry --include-tests` and `bin/exhale complexity`; don't
introduce new duplicate code or methods over the complexity floor.

After the feature or fix is built and `rake` is green, run `/loop-review` until it comes back clean (see
[Review and release skills](#review-and-release-skills)).

Live provider tests are in `examples/` (`bin/live-examples` runs them all, loading keys from `~/.zshrc`; or
`bundle exec ruby examples/<provider>_example.rb`). They need real
API keys and cost money, so they run during `/prep-release`, not in CI. Never delete an assertion, mark a
spec pending, or rescue-and-swallow to get green.

## Runtime dependencies

The gem's runtime dependencies are `schematist` (the schema DSL RubyLLM 2.0 uses) and `json_schemer`. Keep it that
way:

- **Never add a provider SDK** (`openai`, `anthropic`, `google-generativeai`, …) or an HTTP client gem. Providers are
  reached through an adapter: RubyLLM's (`ruby_llm` is an optional gem, loaded only when its adapter is built, and a
  development dependency here) or the OpenAI-compatible one (stdlib `Net::HTTP`). No code outside
  `lib/squishling/adapters/` may call `RubyLLM` or an HTTP client.
- Development-only gems go in the `Gemfile`'s `:development, :test` group, never the gemspec.
- No Ruby-version-conditional gems in the `Gemfile`: the committed `Gemfile.lock` is installed in frozen
  mode on every Ruby in the CI matrix (3.3–4.0), so it must resolve identically everywhere.
- `examples/`, `spec/`, `bin/`, and agent files are excluded from the packaged gem (see the gemspec).

## Design invariants

Flag any change that breaks one of these; they are behavior contracts, not style:

- **Strict schemas only.** Squishling always requests strict structured output and rejects `strict: false`
  (the OpenAI-compatible adapter's explicit `structured_output: :json_object`/`:none` modes, for servers without it,
  put the schema in the prompt instead; local validation is the guarantee either way).
  Every key is required; "not provided" is expressed as a nullable (`optional`) field.
- **Adapters are the only code that talks to a provider.** An adapter (`Adapter::Base`, `#complete(request)`) is
  stateless: Squishling owns the conversation, validation, retries, and escalation. It raises `ConfigurationError`
  (never retried) or `LLMError`; any other exception propagates unwrapped. A provider's own message, response body,
  and API key never go into an error or log. An adapter keeps its credentials (an API key, headers that may carry
  one) in a `Secret`, not in plain instance variables, so no serializer can write them out. The OpenAI-compatible
  adapter refuses to send a credential over plain `http` to a non-loopback host (unless `allow_insecure_http:`),
  caps a response's size (`max_response_bytes`) and time (`total_timeout`), and refuses a compressed one; those
  limits are non-retried `LLMError`s that name the limit, never the URL or the response. Adapters run on worker
  threads for samples, so they hold no unsynchronized state. Built-in and custom adapters share one `Adapter::Registry`; there is no private path for the
  built-ins. `config.adapter` is process-wide (not per class or step); unset, it auto-detects `ruby_llm`.
- **Classifying a provider failure is the adapter's job; what happens next is Squishling's.** The line is fixed:
  - *The adapter defines* which error a provider failure is: `LLMError` (worth another attempt: rate limit, 5xx,
    timeout, connection, a prompt too long for the model), `ConfigurationError` (credentials, billing, model or
    endpoint), or `RequestRejectedError` (the provider refused the request). Only it knows its provider's status codes,
    error bodies, and wording for an overlong prompt. `Adapter::Base#http_failure` is the shared status mapping
    (408/413/429/5xx, no status, or a success status → `LLMError`; 401/402/403/404/3xx → `ConfigurationError`; every
    other 4xx → `RequestRejectedError`), and `Adapter::Base#context_length?` is the hook where an adapter decides a
    rejection is an overlong prompt (the default reads only the structured `context_length_exceeded` code or type).
    An adapter may match a provider's documented wording for an overflow (the OpenAI-compatible one does, narrowly; a
    match is never repeated), but
    where it can't tell it raises the general error, which errs toward `RequestRejectedError`: that is never
    absorbed by a fallback, so a misjudged setup mistake can't be hidden.
  - *Squishling manages* what follows from the class it is given: retry and escalation (`LLMError` and invalid
    output move on; `ConfigurationError` never does), `squish_fallback` (absorbs `LLMError`, never a
    `ConfigurationError`), the token budget, and `squawk`. Squishling core never inspects a provider's status,
    code, or message; it sees only the adapter's error classes.
- **Same type from both paths.** Deterministic returns (and fallback returns) are validated against the
  schema and typed exactly like LLM results.
- **Validate everything that comes back.** Adapters do not validate structured output and some providers
  don't enforce strict mode; Squishling's own `json_schemer` validation is the guarantee. Conditional keywords
  (`if`/`then`/`else`, `dependentRequired`, `dependentSchemas`) are enforced locally and never sent to the
  provider (`Schema::LOCAL_ONLY_KEYWORDS`).
- **The escalation decides attempts.** A level declares either `model:` (one attempt) or `escalation:` (ordered
  steps with `attempts:`, optionally explicit `priority:`, whose old name `order:` is deprecated); there is no
  separate retry count, and levels are never merged. Steps tied on priority are one tier that rotates per call
  (`Rotation`, counted per class and method): the first model alternates, and the tier's other models are tried before
  the next priority. `rotate: false` pins a tier. A step's `include_when:` Proc (inputs as keywords, on the instance)
  drops it from a call before rotation; a call left with no steps raises `ConfigurationError`.
  Invalid output and `LLMError` move on to the next attempt (a same-chat retry that returns the reply it was just
  rejected for skips the rest of its step's attempts, reported as `repeated:` in `squawk` metadata);
  `ConfigurationError` never does.
- **A budget stops a call, never a request.** `max_total_output_tokens`/`max_total_input_tokens` (config, class,
  method, `squish!`; layered limit by limit, `false` lifts one) are checked before each request the call's `Run` makes
  (escalation attempts, sample rounds, judge attempts), against the tokens its `LLMClient` has tallied from the
  responses so far (mutex-guarded: samples add from worker threads). A request in flight is never cut short, so a call
  can end above the limit by one request; a response without token counts adds nothing. It raises
  `BudgetExhaustedError`, an `InvalidOutputError`, so `squish_fallback` and the "no second rescue path" rule hold.
- **Error taxonomy.** Everything Squishling raises inherits `Squishling::Error`: `ConfigurationError`
  (setup mistakes; never retried, escalated, or passed to fallbacks; a provider 400 or other rejected 4xx is its
  `RequestRejectedError` subclass), `InvalidOutputError` (bad output after every attempt in the escalation;
  `BudgetExhaustedError` is its subclass for a spent token budget), `LLMError` (provider/transport failure after the
  adapter's HTTP retries, `cause` per the adapter, see the invariant on provider text below). Never wrap or swallow
  exceptions raised by the user's own Ruby code.
- **Model output leaves the process only through `InvalidOutputError#raw` and the opt-in `squawk` hook.** Error
  messages and `config.logger` lines carry parse positions and schema paths, never the response itself (the
  documented exceptions are model-chosen extra key names, which `InvalidOutputError#error_details` tags
  `model_derived?`, and the developer's own `squish_validate` messages).
  A provider's or transport's own message is the same: ours carry the error class and HTTP status (a 400's
  `RequestRejectedError` adds the body's status and code when they are plain tokens, as `provider_status` and
  `provider_code`). The cause chain is covered too, since error trackers walk it: only adapters set `cause`, and an
  adapter puts a provider exception that carries a response body there only as `sanitized_cause` (`Adapter::Base`; an
  `Adapter::ProviderFailure` with the class, HTTP status, and backtrace, built fresh, never a copy of the original).
  The RubyLLM adapter's `keep_cause: true` is the developer's opt-in to the original; core never touches `cause`.
  Transport errors that carry no body may stay as the cause.
- **A stopped call is reported to `squawk` once.** A `BudgetExhaustedError` or `DisagreementError` ends a call with no
  attempt of its own to report, so `Invoker` sends one final report for it (`stopped:`, `final: true`, no output), for
  built-in and custom harnesses alike, before `squish_fallback` runs. Each error is reported once, even when it passes
  through an outer squished call.
- **Only named context leaves the process.** The LLM sees method arguments, `squish_context` values, a
  `squish!` call's `context:`, and source the developer explicitly passes to `append_to_purpose` — never
  instance variables wholesale. Exceptions in context are sent as class and message only. The one model-generated
  exception: escalating to a new step forwards the previous step's rejected output (capped at
  `Invoker::MAX_FORWARDED_CHARS`) to that step's provider, which may differ; a step can opt out with
  `forward_rejected: false`.
- **Params can't override what Squishling owns.** Provider-specific params are merged into the request alongside
  what the adapter builds (RubyLLM's `with_provider_options`; the OpenAI-compatible body, where Squishling's keys win), so `Params::RESERVED_KEYS` (model, messages, structured-output format, tools, streaming) stay rejected. A
  provider 400 is a `ConfigurationError`, never something a fallback absorbs.
- **No silent shadowing.** `include Squishling` raises `ConfigurationError` if the class inherits a method it would
  override (`Collisions`), and only adds the `result` alias when the class has no `result`. Classes' own methods win.
- **Verification makes no request and holds classes weakly.** Every class that does `include Squishling` (and each
  subclass) is recorded in `ClassRegistry`, a mutex-guarded `ObjectSpace::WeakMap`, so reloaded classes can be
  collected; a named class replaced by a reload is left out of `Squishling.squished_classes`. `Squishling.verify`
  builds schemas and checks resolved settings and callable keywords, collecting every problem; it never calls an
  adapter's `complete`/`judge` or runs the developer's own code. Add new ahead-of-runtime checks to `Verifier`.
- **Thread/fiber safety.** Routing state is fiber-local; shared caches and `Rotation`'s call counts are mutex-guarded.
  Don't add unsynchronized class-level mutable state. `Run#samples` (every harness's samples, the squishsum ones
  included) sends the sample requests on worker threads (`LLMClient#concurrently`), and only the requests: parsing, validation,
  the harness's own code, and every Squishling callback (`squish_validate`, `compare:`, procs) run on the caller's
  thread, and a `Run`'s primitives raise `ConfigurationError` when called from any other. (The adapter carries its request
  context to the workers: `capture_context`/`with_context`. RubyLLM instrumentation subscribers fire on the worker
  threads.) Workers must not enter the Rails executor: the caller already holds it,
  and a second interlock share can deadlock against a pending code reload.
- **Observers see metadata and usage, around the request.** `config.observer` (`Squishling::Observer`) wraps each
  provider request (`LLMClient#ask`/`#judge`) on the thread that makes it, so a sample's observer runs on its worker
  thread. The `Observer::Call` it receives holds label, purpose (the fully rendered system prompt, so as sensitive as the
  prompt itself), harness, `handed_off` (whether `squish!` sent the
  call), role/sample, attempt/attempts, model/provider, and request type; the block's `yield` returns an
  `Observer::Usage` (token counts and model). Never
  inputs, context, or output: the observer's return value is ignored and the real response goes to Squishling's own
  caller, so output still leaves only through `InvalidOutputError#raw` and `squawk`. An observer's own exceptions
  propagate unwrapped. With `observer` nil, the Coolhand observer is used when the `coolhand` gem is loaded and
  configured (no gem dependency, and it must never break a call it can't declare).
- **Harnesses don't add a second rescue path.** Every harness failure surfaces as `InvalidOutputError`
  (disagreements as its `DisagreementError` subclass, a spent budget as `BudgetExhaustedError`) or `LLMError`, so `squish_fallback` stays the only fallback.
- **Built-ins and custom harnesses share one interface.** `:escalation`, `:squishsum`, and `:judged_squishsum` are
  `Harness::Base` subclasses written against `Run`, and custom harnesses are registered in the same mutex-guarded
  `Harness::Registry`. A harness's return value must be a typed result its `Run` produced (`Invoker#accepted`), so
  validation can't be skipped. Options are validated when the harness is declared, before any request. Don't give the
  built-ins a private path that custom harnesses can't use.
- **Test support is opt-in and framework-free.** `squishling/testing` is never required by `lib/squishling.rb`, adds no
  runtime dependency, and needs no test framework or mocking library (the Minitest and RSpec mixins only call the
  host's `flunk` / raise RSpec's failure). It is a real `Adapter::Base` installed through `config.adapter` (and a
  `Testing::Observer` that tells it the role/sample/attempt), so it follows the adapter contract rather than patching
  any provider SDK. Its stand-ins must stay honest: `stub_result` builds results through the method's schema, and the
  re-ask/escalation parsing reads `Run::Messages`, the one source of those texts. Its errors (`UnscriptedRequestError`,
  `ProviderCallError`, `SetupError`) are not `Squishling::Error`s, so a `squish_fallback` can't absorb them.
  `Testing.reset!` restores only what the helpers changed.

## Public API

The public surface is `Squishling.configure`/`config`, the adapter plugin point (`config.adapter`,
`Squishling.register_adapter`/`adapters`/`reset_adapters!`, `Squishling::Adapter::Base` (`complete`, the optional
`judgments?`/`judge`/`capture_context`/`with_context`, the `http_failure`/`context_length?` classification
helpers, and the `sanitized_cause` helper with its `Adapter::ProviderFailure`), `Adapter::Request`,
`Adapter::Response`, and the built-in `Adapters::RubyLLM` and `Adapters::OpenAICompatible` with their options), the
`include Squishling` DSL
(`squishling` — including its
`model:`/`escalation:` (steps with `model:`, `attempts:`, `priority:`, `rotate:`, `provider:`, `params:`,
`forward_rejected:`, `retry_temperature:`, `include_when:`)/`provider:`/`params:`/
`harness:` (`type:`, `compare:`, `judge:` (a step, plus `type: :chat | :judgment` and `min_confidence:`),
`judge_instructions:`)/`append_to_purpose:`/`squawk:`/`squawk_on:` options — `purpose`, `append_to_purpose`,
`output_schema`, `squish_when`, `squish_context`, `squish` (including `validate:`/`harness:`/`squawk:`/`squawk_on:`),
`squish_validate`, `squish_fallback`, `result`/`squishling_result`, `squish!` (including
`model:`/`escalation:`/`harness:`), and the `max_total_output_tokens:`/`max_total_input_tokens:` options of
`squishling`, `squish`, and `squish!`), `Squishling::Configuration` options (including `default_harness`,
`default_max_total_output_tokens`/`default_max_total_input_tokens`, `observer`, `squawk_on`, and `squawk`, whose
`output:`/`metadata:`/`error:` keywords are public), `Squishling::Observer::Call`/`Usage`,
`Squishling::Harness::DEFAULT_JUDGE_INSTRUCTIONS`, result objects (`squished?`, `to_h`, `[]`), and the error classes
(including `InvalidOutputError#error_details` (`InvalidOutputError::Detail`: `message`, `source`,
`model_derived?`), `InvalidOutputError#models`, `DisagreementError#candidates`/`verdict`/`reason`,
`RequestRejectedError#provider_status`/`provider_code`, `BudgetExhaustedError#limit`/`max`/`used`, and
`VerificationError#report`/`problems`). The verification surface is public too: `Squishling.verify`/`verify!`/
`squished_classes`, `Squishling::Verification::Report`/`Problem`, the `squishling:verify` rake task, and the
`be_squishling_valid` matcher (`require "squishling/rspec"`). The custom-harness plugin point is public too:
`Squishling.register_harness`/`harnesses`/`reset_harnesses!`, `Squishling::Harness::Base` (`option` and its types,
`call(run, **options)`, `validate_options!`), the `Squishling::Run` primitives a harness gets (`receiver`, `inputs`,
`label`, `steps`, `stages`, `stage`, `escalate`, `samples`, `judge`, `agree?`, `log`) with
`Squishling::Judge::Verdict`, and the squawk `metadata` keys `role:`/`sample:`/`repeated:`/`stopped:`. The opt-in test
support is public too: `Squishling::Testing` (`install`, `forbid_provider_calls!`, `no_llm_call`, `reset!`,
`stub_result`/`stub_error`, `validate`/`fallback_for`/`preview`, `valid_reply_for`/`invalid_reply_for`,
`capture_squawk`/`with_squawk`), its script DSL (`step`/`sample`/`judge`, `reply`/`fail`/`once`, `Reply`),
`Testing::Adapter#requests`/`conversations` with `Testing::Request`, and the `Testing::Minitest` / `Testing::RSpec`
mixins. Don't break it without a clear migration path in the changelog.

## Changelog and versioning

Do not add `CHANGELOG.md` entries or bump `lib/squishling/version.rb` on feature/fix branches or in PRs. The
`/prep-release` skill is the sole owner of both — it writes changelog entries for the PRs actually shipping in
a release and bumps the version once, at release time.

Per-PR changelog edits create merge conflicts across concurrent branches for no benefit, since the entries get
rewritten from the final, user-approved set of merged PRs anyway. Leave `CHANGELOG.md` and `version.rb` alone
in your PR.

Releases publish to RubyGems via Trusted Publishing when a `vX.Y.Z` tag is pushed. Agents never create or push
tags, run `rake release`, or `gem push`. The one exception: `/finish-release`, invoked by the user, is the
sanctioned path for merging the release PR and pushing the release tag (it still never runs `rake release` or
`gem push`).

## Commits and PRs

Author commits and PRs as the local machine's GitHub user (whatever `git config user.name`/`user.email` and
`gh api user` report), never as Claude or any other agent. Don't add `Co-Authored-By: Claude` trailers or
"Generated with Claude Code" footers to commit messages or PR descriptions. A human owns every change, and a
single, accurate author makes it easy to track who is responsible for what.

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
