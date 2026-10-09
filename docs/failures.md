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

Squishling validates output itself with [json_schemer](https://github.com/davishmcclurg/json_schemer), because
RubyLLM doesn't, and some providers don't enforce strict mode. When the next attempt is on the same step (same
model, provider, params, and `forward_rejected:`), the re-ask happens in the same conversation, so the model sees
what it got wrong. A different step gets a fresh chat with the original input plus the rejected output (truncated to
4,000 characters) and its errors; set `forward_rejected: false` on a step to leave both out. `InvalidOutputError`
exposes `errors`, `raw` (the last response), `attempts`, and `models` (the model tried on each attempt). With a
`logger` configured, every escalation is logged as a warning.

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
| `Squishling::ConfigurationError` | Missing instructions or schema, a non-strict schema, invalid or reserved params, an invalid `model:`/`escalation:` declaration, an invalid `append_instructions` item or unavailable source, bad credentials, an unknown model, a request the provider rejects (400) |
| `Squishling::InvalidOutputError` | LLM output still invalid (schema or `squish_validate`) after every attempt in the escalation, or a deterministic/fallback return that doesn't match the schema |
| `Squishling::LLMError` | The provider call failed on the last attempt in the escalation, after RubyLLM's own retries, including context-length errors (`cause` holds the original) |

Errors raised by your own Ruby code are not wrapped.

## Fallbacks

Use `squish_fallback` to decide what happens when every attempt fails, with `InvalidOutputError` or
`LLMError`.
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
