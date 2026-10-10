# Failure handling

## When the LLM fails

Every squished call works through its [escalation](configuration.md#models-and-escalation), one attempt at a time.
A failed attempt moves on to the next one; once the last fails, the error is raised (or handed to the
[fallback](#fallbacks)). A plain `model:` makes a single attempt.

| Failure | What Squishling does |
|---|---|
| Rate limit, 5xx, overload, timeout, connection error | RubyLLM retries at the HTTP level first (`RubyLLM.config.max_retries`, default 3). If it still fails, moves to the next attempt in a fresh chat; on the last attempt, raises `Squishling::LLMError` with the original exception as its `cause`. |
| Bad API key, unknown model, missing provider config | Raises `Squishling::ConfigurationError`. Never escalated, never sent to the fallback. |
| Provider rejects the request (400 Bad Request), e.g. an unsupported `temperature` or a schema it won't accept | Raises `ConfigurationError` with the provider's message and the params in use. Never escalated, never sent to the fallback, so a setup mistake can't be silently covered up on every call. |
| Empty or `nil` response (e.g. a refusal or a max-tokens cutoff) | Moves to the next attempt, then raises `Squishling::InvalidOutputError` |
| Malformed or truncated JSON | Moves to the next attempt, then raises `InvalidOutputError`. JSON wrapped in a markdown code fence is accepted. |
| JSON that doesn't match the schema (wrong types, missing or extra keys, `null` in a non-`optional` field, a broken [conditional rule](schemas.md#contracts-beyond-the-schema), root not an object) | Moves to the next attempt with the validation errors, then raises `InvalidOutputError` |
| Schema-valid output that [`squish_validate`](#output-checks-squish_validate) rejects | Moves to the next attempt with your messages, then raises `InvalidOutputError` |
| With a [squishsum or ensemble harness](harnesses.md): two valid samples that differ, with no judge or a judge that rejects both | Raises `Squishling::DisagreementError` (an `InvalidOutputError`), carrying both typed `candidates` |

Squishling validates output itself with [json_schemer](https://github.com/davishmcclurg/json_schemer), because
RubyLLM doesn't, and some providers don't enforce strict mode. When the next attempt is on the same step (same
model, provider, params, and `forward_rejected:`), the re-ask happens in the same conversation, so the model sees
what it got wrong. A different step gets a fresh chat with the original input plus the rejected output (truncated to
4,000 characters) and its errors, so that output is sent to the next step's provider, which may not be the one that
produced it. Set `forward_rejected: false` on a step to leave both out. `InvalidOutputError` exposes `errors`, `raw`
(the last response), `attempts`, and `models` (the model tried on each attempt); for a
[`DisagreementError`](harnesses.md#when-the-harness-fails), `raw` holds both candidates, `attempts` is `nil`, and
`models` has one entry per role (sample a, sample b, then the judge). With a `logger` configured, every
escalation is logged as a warning.

### What ends up in errors and logs

Model output can echo sensitive input, so the raw response is kept in one place: `InvalidOutputError#raw` (plus the opt-in `squawk` hook below).
`InvalidOutputError#message`, `#errors`, and `config.logger` warnings are built from these:

- For unparseable JSON, only the position (`response was not valid JSON (at line 1 column 7)`), never the parser's
  snippet of the response.
- JSON Schema errors, which name the schema path and the rule that failed. They never contain the rejected value, but
  they do name an extra key the model added (`object property at /foo is a disallowed additional property`), and
  that key name is chosen by the model.
- Your own `squish_validate` messages, verbatim. If you interpolate result values into them, those values reach
  the message, the logger, and the next attempt's prompt.
- A fixed message when a response contains a value JSON can't represent (`1e400` parses to `Infinity`, or a string
  with invalid UTF-8).
- At most the first 20 of these errors, plus a count of the rest, so a very large malformed response can't flood
  the retry message or the log.
- For a [`DisagreementError`](harnesses.md#when-the-harness-fails), only what Squishling wrote: a `:judgment` judge's
  choice and probability. A chat judge's `reason` is model-written, so it is available as `#reason` but never in the
  message or logs.

The same applies to anything you log yourself, such as `error.message` in a [fallback](#fallbacks). Use `error.raw`
only where you are willing to store model output. To send the output of every attempt somewhere on purpose, use
[`squawk`](#observing-every-attempt-squawk).

## Observing every attempt (`squawk`)

`squawk` is an opt-in hook for sending what the model returned to an error tracker or tracing tool. It runs after
every LLM attempt, accepted or rejected, and does nothing unless you set it:

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
| `metadata` | `label` (`"Class#method"`), `attempt`, `attempts` (the escalation's length; under a harness, the sample's or judge's own attempts), `final` (the last attempt), `model`, `provider`, `params`, `input` (the JSON sent: arguments and named context only), `usage` (token counts, when RubyLLM reports them) |

- Set it globally with `config.squawk`, per class with `squishling squawk: ...`, or per method with
  `squish :triage, squawk: ...`. The method's hook wins over the class's, which wins over the configured one;
  `squawk: false` silences an inherited hook. Subclasses and `squish!` calls inherit it.
- Any object that responds to `call` works. The hook receives only the keywords it declares, unless it takes `**`,
  so a lambda that wants just `error:` is fine and new metadata fields won't break it.
- It runs inline, so keep it quick. Exceptions it raises propagate unchanged and fail the call, like any of your own
  code, so rescue inside the hook if an outage in your tracing tool shouldn't.
- `output` is the same object the result is built from, so treat it as read-only.
- Under a [harness](harnesses.md), it runs for every sample and judge attempt too, each with its own `input`.
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
| `Squishling::ConfigurationError` | Missing purpose or schema, a non-strict schema, invalid or reserved params, an invalid `model:`/`escalation:` declaration, an invalid `append_to_purpose` item or unavailable source, bad credentials, an unknown model, a request the provider rejects (400) |
| `Squishling::InvalidOutputError` | LLM output still invalid (schema or `squish_validate`) after every attempt in the escalation, or a deterministic/fallback return that doesn't match the schema |
| `Squishling::DisagreementError` | A subclass of `InvalidOutputError`: a [squishsum or ensemble harness](harnesses.md#when-the-harness-fails)'s samples disagreed and no judge accepted either. `candidates`, `verdict`, and `reason` describe what happened |
| `Squishling::LLMError` | The provider call failed on the last attempt in the escalation, after RubyLLM's own retries, including context-length errors (`cause` holds the original) |

Errors raised by your own Ruby code are not wrapped.

## Fallbacks

Use `squish_fallback` to decide what happens when the LLM path fails with `InvalidOutputError` (including a
`DisagreementError`) or `LLMError`. It's the one fallback for every [harness](harnesses.md).
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
