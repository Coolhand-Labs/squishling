# Routing: Ruby or LLM

Every squished method call is routed to one of two paths: the method's own Ruby implementation (the
*deterministic* path) or an LLM call (the *elastic* path). Both return the same validated, typed result.

## When a call goes to the LLM

A squished call goes to the LLM when either:

- **its `squish_when` predicate is truthy.** The predicate receives the method's inputs as keywords and is
  evaluated against the instance, so it can read instance state too. Accept `**` to ignore inputs you
  don't need.
- **the method has no implementation.** It's either not defined, or it raises `NotImplementedError`.

```ruby
class InvoiceParser
  include Squishling
  # ...
  squish_when { |client_name:, **| !HARDENED_CLIENTS.include?(client_name) }
end

def summarize(text) = raise NotImplementedError   # elastic until someone writes it
```

Otherwise the Ruby implementation runs. A `Hash` it returns is validated against the schema and turned into
the same typed result the LLM path produces. `result(...)` (alias `squishling_result`) does the same
explicitly. Invalid deterministic output raises `Squishling::InvalidOutputError` too, so a hardened path
can't silently drift from the contract.

A `NotImplementedError` raised anywhere inside the method, including from code it calls, also routes to the
LLM.

## Hardening a path

This is the workflow from [Elastic Software](https://everythingengineer.substack.com/p/beginners-write-software-with-ai):

1. Ship the class with instructions and a schema but no implementation. Every call goes to the LLM.
2. Watch which inputs carry the volume. `squished?` on each result tells you which path served it.
3. Write Ruby for the high-volume cases and narrow `squish_when` so only the rest go to the LLM.

Callers never change, because both paths return the same result class.

## Entry points

`call` is squished by default, and `InvoiceParser.call(...)` is shorthand for `new.call(...)`. Squish other
methods with `squish`, optionally overriding the class-level settings per method:

```ruby
class TicketTriager
  include Squishling

  squish_context :customer_tier, :product   # instance state sent alongside the arguments

  squish :triage, instructions: "Assign a priority and team.", model: "claude-haiku-4-5" do
    string :priority, enum: %w[low med high]
    string :team
  end

  def initialize(customer_tier:, product:, db:)
    @customer_tier, @product, @db = customer_tier, product, db
  end

  def triage(ticket_text) = raise NotImplementedError
end
```

`squish` accepts:

- `instructions:`
- `output_schema:` (or a schema block)
- `model:` or `escalation:`, `provider:`, and `params:` (generation params; see [Configuration](configuration.md))
- `when:`, a predicate proc
- `validate:` and `fallback:` (see [Failure handling](failures.md))

`squish` can come before or after the method's `def`.

## What the LLM sees

- **System prompt:** your instructions (a String, or a Proc evaluated against the instance) plus a short note
  describing the input format.
- **User message:** JSON with the method's arguments, mapped to their parameter names. Any
  `squish_context` values go under `"context"`:

```json
{ "arguments": { "ticket_text": "API is down!" },
  "context":   { "customer_tier": "enterprise", "product": "API" } }
```

- **Retries and escalation:** another attempt of the same step gets the validation errors in the same conversation. A
  later [escalation](configuration.md#models-and-escalation) step, which may be a different provider (say, local
  Ollama, then hosted Anthropic Claude), gets the same JSON plus the previous model's rejected output and the
  errors, including any messages your [`squish_validate`](failures.md#output-checks-squish_validate) check
  returned. Don't put data in those messages that you wouldn't send as an argument.

`squish_context` names are read from a method of that name if there is one, otherwise from the instance
variable. Only context you name is sent. Instance variables are never dumped wholesale, so API clients,
database connections, and secrets stay out of the prompt.
