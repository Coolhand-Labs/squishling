# Squishling

Elastic Ruby classes. A squishling class can run as ordinary deterministic Ruby code, **or** bypass its
implementation and send its inputs through an LLM (via [RubyLLM](https://rubyllm.com)), returning a
schema-validated, typed result. Callers can't tell the difference.

Inspired by [Elastic Software](https://everythingengineer.substack.com/p/beginners-write-software-with-ai):
start flexible with AI, then harden high-volume paths into code as the economics justify it.

A squishling needs two things:

1. **Instructions**: the system prompt.
2. **An output schema**: the shape of the result, validated on both paths.

## Installation

```ruby
gem "squishling"
```

Configure RubyLLM as usual (API keys, etc.), then optionally set a universal model:

```ruby
Squishling.configure do |config|
  config.default_model = "claude-sonnet-5-5" # falls back to RubyLLM's default when nil
  config.default_provider = nil              # only needed for models missing from RubyLLM's registry
  config.max_retries = 1                     # re-asks on schema-invalid output before raising
  config.logger = Rails.logger               # optional; logs when calls are routed to the LLM
end
```

## Quick start

```ruby
class InvoiceParser
  include Squishling

  squishling model: "claude-sonnet-5-5"     # class-specific model (optional)
  instructions "Extract invoice fields from the client's raw data."
  output_schema do
    string :invoice_number
    number :total
    array :line_items do
      object do
        string :description
        number :amount
      end
    end
  end

  # Clients we've hardened run Ruby; everyone else goes to the LLM.
  squish_when { |client_name:, **| client_name != "acme" }

  def call(client_name:, data:)
    parsed = AcmeParser.parse(data)
    result(invoice_number: parsed.id, total: parsed.sum, line_items: parsed.lines)
  end
end

r = InvoiceParser.call(client_name: "globex", data: csv)
r.total          # => 1250.0
r[:total]        # => 1250.0
r.line_items.first.description
r.to_h           # deep Hash with symbol keys
r.squished?      # => true (came from the LLM)
```

## Routing

A squished call goes to the LLM when either:

- **its `squish_when` predicate is truthy.** The predicate receives the method's inputs as keywords and
  is evaluated against the instance, so it can read instance state too. Accept `**` to ignore inputs you
  don't need.
- **the method has no implementation.** It's either not defined, or it raises `NotImplementedError`.

```ruby
def summarize(text) = raise NotImplementedError   # elastic until someone writes it
```

Otherwise the Ruby implementation runs. A `Hash` it returns is validated against the schema and turned into
the same typed result the LLM path produces. `result(...)` (alias `squishling_result`) does the same
explicitly. Invalid deterministic output raises `Squishling::InvalidOutputError` too, so a hardened path
can't silently drift from the contract.

## Entry points

`call` is squished by default (and `InvoiceParser.call(...)` is shorthand for `new.call(...)`). Squish other
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

`squish` accepts `instructions:`, `output_schema:` (or a schema block), `model:`, and `when:` (a predicate proc).

## What the LLM sees

- **System prompt:** your instructions plus a short note describing the input format.
- **User message:** JSON with the method's arguments, mapped to their parameter names. Any
  `squish_context` values go under `"context"`:

```json
{ "arguments": { "ticket_text": "API is down!" },
  "context":   { "customer_tier": "enterprise", "product": "API" } }
```

Only context you name is sent. Instance variables are never dumped wholesale.

## Output schemas

`output_schema` (and `squish`) accept any of:

- a [RubyLLM::Schema](https://github.com/danielfriis/ruby_llm-schema) DSL block
- a `RubyLLM::Schema` subclass
- a raw JSON Schema `Hash`

Squishling only supports **strict** output schemas: it always asks RubyLLM for strict structured output, and a
schema declaring `strict: false` (or `strict false` in the DSL) raises `Squishling::ConfigurationError`. With raw
hashes, follow your provider's strict-mode rules (e.g. list every property in `required` and set
`additionalProperties: false`).

Object schemas produce `Data` result classes (nested objects become nested `Data`). Both paths of a
squished method return the same class.

## Invalid LLM output

Output is validated with [json_schemer](https://github.com/davishmcclurg/json_schemer). On failure, Squishling
re-asks in the same conversation with the validation errors, up to `max_retries` times. After that it raises
`Squishling::InvalidOutputError`, which exposes `errors` and `raw`.

## Model resolution

1. per-method `squish ..., model:`
2. per-class `squishling model:`
3. `Squishling.config.default_model`
4. RubyLLM's `default_model`

Each level also accepts a `provider:` (`config.default_provider` for the universal one). A provider is
paired with the model declared at the same level. You only need it for models missing from RubyLLM's
bundled registry, such as newly released ones; Squishling then tells RubyLLM to assume the model exists:

```ruby
squishling model: "gpt-6-luna", provider: :openai
```

Settings, schemas, predicates and context are inherited by subclasses, and subclass overrides are routed too.

## Development

```sh
bundle install
bundle exec rspec        # offline; RubyLLM is stubbed
```

Live tests against real providers (Claude Haiku, GPT-6 Luna) live in [`examples/`](examples/README.md).

## License

Apache-2.0
