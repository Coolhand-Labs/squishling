# Output schemas and typed results

## Declaring a schema

`output_schema` (and `squish`) accept any of:

- a [Schematist](https://github.com/crmne/schematist) DSL block (the schema DSL RubyLLM 2.0 uses)
- a `Schematist::Schema` subclass (`RubyLLM::Schema` too, if your app uses the `ruby_llm-schema` shim)
- a raw JSON Schema `Hash`

```ruby
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

output_schema InvoiceSchema   # class InvoiceSchema < Schematist::Schema

output_schema(
  type: "object",
  properties: { sentiment: { type: "string", enum: %w[positive negative neutral] } },
  required: ["sentiment"],
  additionalProperties: false
)
```

## Strict schemas only

Squishling only supports **strict** output schemas: it always asks RubyLLM for strict structured output, and a
schema declaring `strict: false` raises `Squishling::ConfigurationError`. RubyLLM 2.0 on its own would send a
schema with optional properties non-strict; Squishling always sets the flag explicitly, so it stays strict.

With raw hashes, follow your provider's strict-mode rules (e.g. list every property in `required` and set
`additionalProperties: false`). The DSL generates compliant schemas for you, as long as you don't mark fields
`required: false`. Use `optional` instead (below). A schema the provider rejects in strict mode raises
`ConfigurationError`.

Not every provider enforces strict mode server-side (Anthropic, for example, doesn't receive the flag), so
Squishling validates every result itself. See [Failure handling](failures.md).

## Typed results

Object schemas produce `Data` result classes, and nested objects become nested `Data`. Both paths of a
squished method return the same class.

```ruby
r = InvoiceParser.call(client_name: "globex", data: csv)
r.total                          # => 1250.0
r[:total]                        # => 1250.0
r.line_items.first.description   # nested Data
r.to_h                           # deep Hash with symbol keys
r.squished?                      # => true when it came from the LLM
```

On the deterministic path, return a `Hash` or build the result with `result(...)`. Either way it's validated
against the schema.

## Optional vs. empty

Strict mode requires **every key to be present**, so a field can't be left out. To say "not provided", make the
field nullable with the DSL's `optional`. The key stays required, but its value may be `null`:

```ruby
output_schema do
  array :symptoms, of: :string      # always a list; [] means "none"
  optional :allergies do            # [] means "none", nil means "not mentioned"
    array of: :string
  end
  optional :vitals do               # a typed Data object, or nil
    object do
      integer :heart_rate
    end
  end
end
```

`optional` produces `anyOf: [<schema>, {type: "null"}]`, which is strict-compatible. Squishling types the non-null
branch as usual: `vitals` is a `Data` object or `nil`, and a list of objects is a list of `Data` objects. In a raw
JSON Schema, `type: ["array", "null"]` works too. A union with more than one non-null branch is ambiguous, so its
values come back as plain hashes. If you need the model to tell "none" apart from "not mentioned", say so in your
instructions.
