# Failure handling

## When the LLM fails

Every squished call works through its [escalation](configuration.md#models-and-escalation), one attempt at a time.
A failed attempt moves on to the next one; once the last fails, the error is raised (or handed to the
[fallback](#fallbacks)). A plain `model:` makes a single attempt.

| Failure | What Squishling does |
|---|---|
| Rate limit, 5xx, overload, timeout, connection error | The [adapter](adapters.md) retries at the HTTP level first (RubyLLM: `RubyLLM.config.max_retries`, default 3; OpenAI-compatible: `max_retries:`, default 2). If it still fails, moves to the next attempt in a fresh chat; on the last attempt, raises `Squishling::LLMError` with a [sanitized `cause`](#the-cause-of-a-provider-failure) (when the adapter has one: the RubyLLM adapter always does; the OpenAI-compatible adapter for transport errors, not for HTTP statuses). |
| Bad API key, unknown model, missing provider config | Raises `Squishling::ConfigurationError`. Never escalated, never sent to the fallback. |
| Provider rejects the request (400 Bad Request), e.g. an unsupported `temperature` or a schema it won't accept | Raises `Squishling::RequestRejectedError` (a `ConfigurationError`) naming the error class, the HTTP status, and the provider's error status/code when its body carries one (`INVALID_ARGUMENT`, `invalid_request_error`). They are also on `error.provider_status` and `error.provider_code` (nil when absent); only plain tokens are kept, never the provider's message. The message points at a param only when the provider named it, and otherwise says the params, output schema, or input may be invalid. The provider's own message is not on `cause` either unless you opt in (see [the cause of a provider failure](#the-cause-of-a-provider-failure)). It is never retried, so if you know a given code means "this input was bad", rescue it and decide for yourself. Never escalated, never sent to the fallback, so a setup mistake can't be silently covered up on every call. |
| Empty or `nil` response (e.g. a refusal or a max-tokens cutoff) | Moves to the next attempt, then raises `Squishling::InvalidOutputError`. When the provider reported a max-tokens cutoff, the error says so and [`truncated?`](#a-cutoff-or-a-wrong-answer) is true. |
| Malformed or truncated JSON | Moves to the next attempt, then raises `InvalidOutputError`. JSON wrapped in a markdown code fence is accepted. |
| JSON that doesn't match the schema (wrong types, missing or extra keys, `null` in a non-`optional` field, a broken [conditional rule](schemas.md#contracts-beyond-the-schema), root not an object) | Moves to the next attempt with the validation errors, then raises `InvalidOutputError` |
| Schema-valid output that [`squish_validate`](#output-checks-squish_validate) rejects | Moves to the next attempt with your messages, then raises `InvalidOutputError` |
| The call has used its [token budget](#capping-a-calls-cost-token-budgets) | Stops before the next attempt and raises `Squishling::BudgetExhaustedError` (an `InvalidOutputError`) |
| With a [squishsum harness](harnesses.md): two valid samples that differ, with no judge or a judge that rejects both | Raises `Squishling::DisagreementError` (an `InvalidOutputError`), carrying both typed `candidates` |

Squishling validates output itself with [json_schemer](https://github.com/davishmcclurg/json_schemer), because
adapters don't, and some providers don't enforce strict mode. When the next attempt is on the same step (same
model, provider, params, `forward_rejected:`, and `retry_temperature:`), the re-ask happens in the same conversation, so the model sees
what it got wrong. If that re-ask returns the same reply it was just told was invalid, Squishling doesn't spend the
step's remaining attempts: it moves straight to the next step (or raises `InvalidOutputError`, when this was the
last), so size `attempts:` for replies that can differ. Set `retry_temperature:` on a step to vary the temperature
of its same-chat retries. A different step gets a fresh chat with the original input plus the rejected output
(truncated to 4,000 characters) and its errors, so that output is sent to the next step's provider, which may not be the one that
produced it. Set `forward_rejected: false` on a step to leave both out. `InvalidOutputError` exposes `errors`,
`error_details` (the same messages, each tagged with where it came from; see below), `raw`
(the last response), `attempts`, `models` (the model tried on each attempt), and `finish_reason` (why the provider
stopped on the last one). For a [`DisagreementError`](harnesses.md#when-the-harness-fails), `raw` holds both
candidates, `attempts` and `finish_reason` are `nil`, and `models` has one entry per role (sample a, sample b, then
the judge). With a `logger` configured, every
escalation is logged as a warning.

### A cutoff or a wrong answer

An empty or half-written reply can mean the model was cut off at the output cap, not that it answered wrongly. The
provider's stop reason tells them apart: `InvalidOutputError#finish_reason` and `squawk`'s `metadata[:finish_reason]`
hold it as a Symbol (`:stop`, `:max_tokens`, `:content_filter`, or the provider's own spelling; `nil` when it reported
none), and `truncated?` is true for `:max_tokens`. A truncated error's message and the log line say so.

```ruby
rescue Squishling::InvalidOutputError => e
  e.truncated? # => true: raise max_output_tokens, rather than tuning the prompt or validator
```

Providers that count thinking against the cap need `max_output_tokens` to leave room for the thinking budget plus the
answer: `thinking: { budget: 8192 }` with `max_output_tokens: 8192` leaves none, so every reply that uses its full
budget is cut off before any JSON is written.

### What ends up in errors and logs

Model output can echo sensitive input, so the raw response is kept in one place: `InvalidOutputError#raw` (plus the opt-in `squawk` hook below).
`InvalidOutputError#message`, `#errors`, and `config.logger` warnings are built from these:

- For unparseable JSON, only the position (`response was not valid JSON (at line 1 column 7)`), never the parser's
  snippet of the response.
- JSON Schema errors, which name the schema path and the rule that failed. They never contain the rejected value, but
  they do name an extra key the model added (`object property at /foo is a disallowed additional property`), and
  that key name is chosen by the model. These are the only entries Squishling itself fills with model-chosen text; see
  [telling the entries apart](#telling-the-entries-apart).
- Your own `squish_validate` messages, verbatim. If you interpolate result values into them, those values reach
  the message, the logger, and the next attempt's prompt.
- A fixed message when a response contains a value JSON can't represent (`1e400` parses to `Infinity`, or a string
  with invalid UTF-8).
- For a failed provider request (`LLMError`, and the `ConfigurationError` for a 400, bad credentials, or a forbidden
  key), only the error class and HTTP status, plus a 400's provider status and code when they are plain tokens. The provider's own message can echo request content or part of an API
  key, and error trackers report the whole `cause` chain, so it is not on `cause` either unless you
  [opt in](#the-cause-of-a-provider-failure).
- At most the first 20 of these errors, plus a count of the rest, so a very large malformed response can't flood
  the retry message or the log.
- For a [`DisagreementError`](harnesses.md#when-the-harness-fails), only what Squishling wrote: a `:judgment` judge's
  choice and probability. A chat judge's `reason` is model-written, so it is available as `#reason` but never in the
  message or logs.

#### Telling the entries apart

`InvalidOutputError#errors` is an Array of Strings. `#error_details` is the same list as
`Squishling::InvalidOutputError::Detail` values (`message`, `source`), so a sink with its own control syntax (a chat
webhook, HTML, a markdown renderer) can escape only what needs it:

| `source` | Where the message came from | `model_derived?` |
|---|---|---|
| `:schema` | A JSON Schema error. It can name a key the model chose. | `true` |
| `:validator` | Your own [`squish_validate`](#output-checks-squish_validate) message, verbatim. Never flagged, so escape it too if you interpolate result values into it. | `false` |
| `:parse` | A message about a response or return value that didn't parse (not valid JSON, empty, a value JSON can't represent). | `false` |
| `:squishling` | Other text Squishling or a [custom harness](harnesses.md#when-the-harness-fails) wrote, such as the "... and N more errors" notice. | `false` |

```ruby
squish_fallback do |error, **|
  trusted = error.error_details.reject(&:model_derived?).map(&:message)
  notify_channel("squishling rejected output: #{trusted.first(2).join('; ')}")
  # ...
end
```

The same applies to anything you log yourself, such as `error.message` in a [fallback](#fallbacks). Use `error.raw`
only where you are willing to store model output. To send the output of every attempt somewhere on purpose, use
[`squawk`](#observing-every-attempt-squawk).

### The cause of a provider failure

A provider's own exception (RubyLLM's, say) carries the provider's response body in its message and `response`, and the
body can echo your request. Error trackers such as Sentry report the whole `cause` chain, so an `LLMError`,
`ConfigurationError`, or `RequestRejectedError` raised for a failed request does not carry that exception as its
`cause`. The [RubyLLM adapter](adapters.md#ruby_llm) puts a `Squishling::Adapter::ProviderFailure` there instead: its
message is the original's class and HTTP status (`RubyLLM::RateLimitError, HTTP 429`), and it has the original's
backtrace, but none of its message, response, or other state. Transport errors that carry no body (the OpenAI-compatible
adapter's timeouts and connection failures) are passed through as they are.

To get the original back for debugging, accept that it reaches your tracker and set `keep_cause: true`:

```ruby
Squishling.configure do |config|
  config.adapter = { type: :ruby_llm, keep_cause: true }
end
```

Then `error.cause` is the `RubyLLM::Error` itself, with its message and `response`.

## Capping a call's cost (token budgets)

`attempts:` limits retries per step, but a call that fails every attempt still pays for all of them, and with
reasoning models the failed attempts are often the longest. A token budget caps what one call may use across every
request it makes, whichever [harness](harnesses.md) it runs:

```ruby
class TicketTriager
  include Squishling

  squishling escalation: [{ model: "claude-haiku-4-5", attempts: 2 }, { model: "claude-sonnet-5-5", attempts: 2 }],
    max_total_output_tokens: 25_000,
    max_total_input_tokens: 200_000
end
```

Before each request, Squishling checks the tokens used so far by the call's earlier requests (the escalation's
attempts, a squishsum harness's samples, and a judge's). Once either total has reached its limit, it makes no more
requests and raises `Squishling::BudgetExhaustedError`. It is an `InvalidOutputError` (so
[`squish_fallback`](#fallbacks) receives it, and existing `rescue InvalidOutputError` code keeps working), and
`rescue Squishling::BudgetExhaustedError` tells it apart from a plain validation failure:

- `limit` is `:max_total_output_tokens` or `:max_total_input_tokens`, `max` its value, and `used` the tokens spent
  so far (`{ input_tokens:, output_tokens: }`).
- `errors` starts with the budget line, followed by the validation errors of the last rejected output, which is in
  `raw` (`nil` when no output was rejected, e.g. the samples were valid but there was no budget left for the judge);
  `attempts` and `models` are the requests made.
- Like any other error message, it carries no model output.

Things to know:

- The first request always runs, and a request already in flight is never cut short, so a call can end above the
  limit by one request (for the squishsum harnesses, one round of samples).
- Tokens are the counts the [adapter](adapters.md) reports (`output_tokens` includes a reasoning model's thinking
  tokens for providers that count them that way). A request that failed reports none, and a provider that reports no
  usage never exhausts a budget.
- The limits are positive Integers. Set them with `Squishling.configure` (`default_max_total_output_tokens`,
  `default_max_total_input_tokens`), `squishling`, `squish :method, ...`, or a [`squish!`](routing.md#handing-off-to-the-llm-with-squish) call.
  The more specific level wins, limit by limit, and `false` lifts a limit set at a wider level.
- To limit a single response instead, use the `max_output_tokens` [generation param](configuration.md#generation-params).

## Observing every attempt (`squawk`)

`squawk` is an opt-in hook for sending what the model returned to an error tracker or tracing tool. It runs after
every LLM attempt, accepted or rejected (unless you narrow it with `squawk_on:`, below), and does nothing unless you
set it:

```ruby
Squishling.configure do |config|
  config.squawk = lambda do |output:, metadata:, error:|
    ObservabilitySolution.record(output, metadata, error) if error
  end
end
```

| Keyword | Value |
|---|---|
| `output` | The raw response: a Hash or String, or `nil` when the provider call itself failed |
| `error` | `nil` for an accepted attempt. Otherwise the `InvalidOutputError` (with `errors` and `raw`) or `LLMError` that ended the attempt |
| `metadata` | `label` (`"Class#method"`), `attempt`, `attempts` (the escalation's length; `attempt` jumps past the attempts a repeated reply skips; under a harness, the sample's or judge's own attempts), `final` (the last attempt, or a rejection after which none follows), `repeated` (`true` when the attempt returned the same reply as the one before it, in the same chat, which skips the step's remaining attempts), `model`, `provider`, `params`, `input` (the JSON sent: arguments and named context only), `usage` (token counts, when the adapter reports them), `finish_reason` (why the provider stopped, e.g. `:stop` or `:max_tokens`; `nil` when unknown or the call failed), `role` (`nil` for an escalation attempt, `:sample`, or `:judge`), `sample` (`"a"`, `"b"`, ... for a sample's attempt, else `nil`) |

- Set it globally with `config.squawk`, per class with `squishling squawk: ...`, or per method with
  `squish :triage, squawk: ...`. The method's hook wins over the class's, which wins over the configured one;
  `squawk: false` silences an inherited hook. Subclasses and `squish!` calls inherit it.
- Limit which attempts reach the hook with `squawk_on:`: `:all` (the default), `:rejections` (only attempts that
  errored), `:retries` (those plus any accepted attempt after the first), or `:final` (the last attempt the escalation
  allows, accepted or not; `metadata[:final]`). A classifier that passes on the first try nearly every time can post
  only when something went wrong:

  ```ruby
  squishling squawk: ->(error:, **) { Tracer.record(error) if error }, squawk_on: :retries
  ```

  Pass a list to combine conditions; the hook runs when any one holds. `squawk_on: %i[rejections final]` reports
  every error, plus the last attempt when it is reached and succeeds. A call accepted on an earlier attempt never
  reaches `:final`. A level's value replaces the one above it; lists are never merged across levels.

  Set it globally with `config.squawk_on`, per class with `squishling squawk_on: ...`, or per method with
  `squish :triage, squawk_on: ...`. It resolves on its own, method then class then configured, so
  `config.squawk_on = :retries` filters every hook, including a class's own, unless that class or method overrides it.
  Under a [harness](harnesses.md), `attempt`, `attempts` and `final` count per sample or judge, so a sample's
  first-attempt success is skipped even while another sample retries, and `:final` fires once per sample and judge.
- Any object that responds to `call` works. The hook receives only the keywords it declares, unless it takes `**`,
  so a lambda that wants just `error:` is fine and new metadata fields won't break it.
- It runs inline, so keep it quick. Exceptions it raises propagate unchanged and fail the call, like any of your own
  code, so rescue inside the hook if an outage in your tracing tool shouldn't.
- `output` is the same object the result is built from, so treat it as read-only.
- Under a [harness](harnesses.md), it runs for every sample and judge attempt too, each with its own `input`, and
  `role`/`sample` say which one it was. A [custom harness](harnesses.md#reporting-to-squawk) reports the same way.
- It isn't called for a `ConfigurationError`, for deterministic and fallback returns, or for an attempt where your own
  `squish_validate` raises (that exception propagates first).

## Output checks (`squish_validate`)

The schema covers shape and types. For rules it can't express, such as cross-field arithmetic or a lookup against
your data, add a Ruby check. It runs only on LLM output that already matches the schema, receives the typed result
plus the method's inputs as keywords, and runs against the instance:

```ruby
class InvoiceParser
  include Squishling
  # ...
  squish_validate do |result, **|
    errors = []
    errors << "total must equal the sum of line_items" unless result.total == result.line_items.sum(&:amount)
    errors << "unknown currency" unless Currency.supported?(result.currency)
    errors
  end
end
```

- Return `nil`, `true`, `""`, or `[]` to accept the output.
- Return a message or an array of messages to reject it. The messages are sent to the next attempt and end up in
  `InvalidOutputError#errors` if every attempt fails. `false` rejects with a generic message.
- A [dry-validation](https://dry-rb.org/gems/dry-validation/) result works too, if your app already uses it:
  `squish_validate { |result, **| InvoiceContract.new.call(result.to_h) }`. Squishling doesn't depend on dry-rb.
- Per method: `squish :triage, validate: ->(result, **inputs) { ... }`. Subclasses inherit the class-level check.
- It doesn't run on deterministic or fallback returns: those are your own code.
- Exceptions raised inside it propagate unwrapped, like any of your own code.

## Errors

| Error | Raised when |
|---|---|
| `Squishling::Error` | Base class for everything below. Raised directly for misuse at call time, e.g. `result` or `squish!` called outside a squished method |
| `Squishling::ConfigurationError` | Missing purpose or schema, a non-strict schema, invalid or reserved params, an invalid `model:`/`escalation:` declaration, an invalid `append_to_purpose` item or unavailable source, bad credentials, an unknown model, a request the provider rejects (400, as `RequestRejectedError`, with `provider_status` and `provider_code`) |
| `Squishling::InvalidOutputError` | LLM output still invalid (schema or `squish_validate`) after every attempt in the escalation, or a deterministic/fallback return that doesn't match the schema |
| `Squishling::DisagreementError` | A subclass of `InvalidOutputError`: a [squishsum harness](harnesses.md#when-the-harness-fails)'s samples disagreed and no judge accepted either. `candidates`, `verdict`, and `reason` describe what happened |
| `Squishling::BudgetExhaustedError` | A subclass of `InvalidOutputError`: the call used up its [token budget](#capping-a-calls-cost-token-budgets) before an attempt was accepted. `limit`, `max`, and `used` describe the budget |
| `Squishling::LLMError` | The provider call failed on the last attempt in the escalation, after the adapter's own retries, including context-length errors (`cause` holds a [sanitized stand-in](#the-cause-of-a-provider-failure), when the adapter has one) |

Errors raised by your own Ruby code are not wrapped.

## Fallbacks

Use `squish_fallback` to decide what happens when the LLM path fails with `InvalidOutputError` (including a
`DisagreementError` or `BudgetExhaustedError`) or `LLMError`. It's the one fallback for every [harness](harnesses.md).
It receives the error plus the method's inputs as keywords, and runs against the instance:

```ruby
class TicketTriager
  include Squishling
  # ...
  squish_fallback do |error, ticket_text:, **|
    Rails.logger.warn("triage fell back: #{error.message}")
    { priority: "medium", team: "support" }   # validated and typed, like a deterministic return
  end
end
```

- The fallback's return value is validated against the schema, like any deterministic return, and its
  `squished?` is `false`. You can also build it with `result(...)`.
- To propagate the error instead, re-raise it with `raise error`.
- Per method: `squish :triage, fallback: ->(error, **inputs) { ... }`.
- Subclasses inherit the class-level fallback.
- Calls handed to the LLM with `squish!` use the fallback too. A fallback can't call `squish!` itself; that
  raises `Squishling::Error` rather than looping. See [Handing off to the LLM](routing.md#handing-off-to-the-llm-with-squish).
- Without a fallback, the error propagates.

Routing to Ruby code isn't automatic on failure. The predicate already chose the LLM for this input, so the
fallback is where you decide whether Ruby code can handle it after all. Calling the method from its fallback
(`call(**inputs)`) runs its Ruby implementation directly, without routing it back to the LLM.
