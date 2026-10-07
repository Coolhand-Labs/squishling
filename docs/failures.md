# Failure handling

## When the LLM fails

| Failure | What Squishling does |
|---|---|
| Rate limit, 5xx, overload, timeout, connection error | RubyLLM retries at the HTTP level (`RubyLLM.config.max_retries`, default 3). If it still fails, raises `Squishling::LLMError`; the original exception is its `cause`. |
| Bad API key, unknown model, missing provider config | Raises `Squishling::ConfigurationError`. Never retried, never sent to the fallback. |
| Provider rejects the request (400 Bad Request), e.g. an unsupported `temperature` or a schema it won't accept | Raises `ConfigurationError` with the provider's message and the params in use. Never retried, never sent to the fallback, so a setup mistake can't be silently covered up on every call. |
| Empty or `nil` response (e.g. a refusal or a max-tokens cutoff) | Re-asks, then raises `Squishling::InvalidOutputError` |
| Malformed or truncated JSON | Re-asks, then raises `InvalidOutputError`. JSON wrapped in a markdown code fence is accepted. |
| JSON that doesn't match the schema (wrong types, missing or extra keys, root not an object) | Re-asks with the validation errors, then raises `InvalidOutputError` |

Squishling validates output itself with [json_schemer](https://github.com/davishmcclurg/json_schemer), because
RubyLLM doesn't, and some providers don't enforce strict mode. Re-asks happen in the same conversation, so the model
sees what it got wrong. `Squishling.config.max_retries` (default 1) sets how many follow-ups are allowed.
`InvalidOutputError` exposes `errors`, `raw` (the last response), and `attempts`.

## Errors

| Error | Raised when |
|---|---|
| `Squishling::Error` | Base class for everything below. Raised directly for misuse at call time, e.g. `result` or `squish!` called outside a squished method |
| `Squishling::ConfigurationError` | Missing instructions or schema, a non-strict schema, invalid or reserved params, an invalid `append_instructions` item or unavailable source, bad credentials, an unknown model, a request the provider rejects (400) |
| `Squishling::InvalidOutputError` | LLM output still invalid after `max_retries`, or a deterministic/fallback return that doesn't match the schema |
| `Squishling::LLMError` | The provider call failed after RubyLLM's own retries, including context-length errors (`cause` holds the original) |

Errors raised by your own Ruby code are not wrapped.

## Fallbacks

Use `squish_fallback` to decide what happens when the LLM path fails with `InvalidOutputError` or `LLMError`.
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
  raises `Squishling::Error` rather than looping. See [Escalating from Ruby](routing.md#escalating-from-ruby-with-squish).
- Without a fallback, the error propagates.

Routing to Ruby code isn't automatic on failure. The predicate already chose the LLM for this input, so the
fallback is where you decide whether Ruby code can handle it after all. Calling the method from its fallback
(`call(**inputs)`) runs its Ruby implementation directly, without routing it back to the LLM.
