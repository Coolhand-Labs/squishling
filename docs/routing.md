# Routing: Ruby or LLM

Every squished method call is routed to one of two paths: the method's own Ruby implementation (the
*deterministic* path) or an LLM call (the *elastic* path). Both return the same validated, typed result.

## Which methods are squished

- **`call`** is squished by default, and `InvoiceParser.call(...)` is shorthand for `new.call(...)`.
- **Any other method** is squished once you declare it with `squish :name, ...` (see [Entry points](#entry-points)).
- **Methods you don't declare are never wrapped.** They're plain Ruby, though a squished method can call them,
  and they can call `squish!` on its behalf.

## When a call goes to the LLM

A squished call runs its Ruby implementation unless one of these sends it to the LLM:

| Trigger | Declared where | Decided |
|---|---|---|
| `squish_when` (or `when:`) predicate is truthy | class, or per method | before Ruby runs |
| The method has no implementation: it isn't defined, or it raises `NotImplementedError` | the method body | when Ruby gives up |
| `squish!` | inside the method, e.g. in a `rescue` | after Ruby has partly run, see [Handing off to the LLM](#handing-off-to-the-llm-with-squish) |

With no predicate and a working implementation, every call runs Ruby.

The predicate receives the method's inputs as keywords and is evaluated against the instance, so it can read
instance state too. Accept `**` to ignore inputs you don't need.

```ruby
class InvoiceParser
  include Squishling
  # ...
  squish_when { |client_name:, **| !HARDENED_CLIENTS.include?(client_name) }
end

def summarize(text) = raise NotImplementedError   # elastic until someone writes it
```

When the Ruby implementation runs, whatever it returns (a `Hash`, `nil`, a string, another schema's result, …)
is validated against the schema and turned into the same typed result the LLM path produces.
`squishling_result(...)` does the same explicitly; `result(...)` is a convenience alias, skipped when the class
already has a `result` (see [Naming and collisions](naming.md)). Invalid deterministic output raises
`Squishling::InvalidOutputError` too, so a hardened path can't silently drift from the contract.

A `NotImplementedError` raised anywhere inside the method, including from code it calls, also routes to the
LLM.

Each call is routed on its own, including a squished method that calls itself on smaller inputs (those
recursive calls must return schema-valid values too). A subclass
override that calls `super` is one call: it's routed once, at the subclass. A call to the method from its own
`squish_when` or `squish_fallback` (or a purpose proc) isn't routed again: it runs the Ruby
implementation, so a fallback can hand the input back to Ruby with `call(**inputs)`. These inner calls
return a `Hash` as the typed result and any other value unchanged; only the outermost return is validated in full.

## Hardening a path

This is the workflow from [Elastic Software](https://everythingengineer.substack.com/p/beginners-write-software-with-ai):

1. Ship the class with purpose and a schema but no implementation. Every call goes to the LLM.
2. Watch which inputs carry the volume. `squished?` on each result tells you which path served it.
3. Write Ruby for the high-volume cases and narrow `squish_when` so only the rest go to the LLM.

Callers never change, because both paths return the same result class.

## Entry points

Squish methods other than `call` with `squish`, optionally overriding the class-level settings per method:

```ruby
class TicketTriager
  include Squishling

  squish_context :customer_tier, :product   # instance state sent alongside the arguments

  squish :triage, purpose: "Assign a priority and team.", model: "claude-haiku-4-5" do
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

- `purpose:` (replaces the class's)
- `append_to_purpose:` (added to the class's, see [Appending to the purpose](#appending-to-the-purpose))
- `output_schema:` (or a schema block)
- `model:` or `escalation:`, `provider:`, and `params:` (generation params; see [Configuration](configuration.md))
- `when:`, a predicate proc
- `validate:` and `fallback:` (see [Failure handling](failures.md))

`squish` can come before or after the method's `def`.

## Handing off to the LLM with `squish!`

Call `squish!` inside a squished method to hand *this call* to the LLM: for example, when the Ruby parser
fails on an input it wasn't written for. It sends the call's arguments, as any LLM call would, and returns the
typed result (`squished?` is `true`, or `false` if the declared `squish_fallback` supplied it). Return that result
from the method.

```ruby
class InvoiceParser
  include Squishling

  purpose "Extract invoice fields from the client's raw data."
  append_to_purpose "Here is the Ruby that parses well-formed invoices, for context on the logic and goals:",
                      self
  output_schema do
    string :invoice_number
    number :total
  end

  def call(client_name:, data:)
    parsed = AcmeParser.parse(data)
    result(invoice_number: parsed.id, total: parsed.sum)
  rescue AcmeParser::ParseError => e
    squish!(append_to_purpose: "The Ruby parser above failed on this input; the error is in the context.",
            context: { parse_error: e })
  end
end
```

`squish!` takes these overrides, all optional and all for this call only:

| Option | Effect |
|---|---|
| `context:` | A Hash sent under `"context"` with any `squish_context` values (a same-named key wins). Exceptions are sent as `{ "class", "message" }`, never their backtrace. |
| `append_to_purpose:` | Added to the declared sections; `false` (alone or first in an Array) drops them for this call |
| `purpose:` | Replaces the purpose |
| `model:` or `escalation:`, `provider:`, `params:` | E.g. send this call to a stronger model, or a whole [escalation](configuration.md#models-and-escalation), when Ruby fails. A `provider:` needs a `model:` or `escalation:`; `params:` merge key by key over the declared ones. |

- **The output schema can't be overridden.** The call still returns the method's result type.
- **Failures** go through the normal LLM path: a declared `squish_fallback` is used, otherwise
  `InvalidOutputError` or `LLMError` is raised. When you call `squish!` from a `rescue`, Ruby sets the
  rescued error as the `cause` of whatever is raised, so you can rescue the LLM failure and raise your own:

  ```ruby
  rescue AcmeParser::ParseError => e
    begin
      squish!(context: { parse_error: e })
    rescue Squishling::InvalidOutputError, Squishling::LLMError
      raise InvoiceUnreadable, "neither Ruby nor the LLM could parse invoice #{client_name}"
    end
  ```

- It works anywhere beneath a squished method on the same object: in the method itself, in a helper it calls,
  or in a parent implementation reached through `super`. Calling it anywhere else, or from a `squish_fallback`
  (which would loop), raises `Squishling::Error`.

## Appending to the purpose

`append_to_purpose` adds sections to the system prompt after the purpose. It takes items, an Array of
them, or a block (treated as a Proc item). Each item is one of:

| Item | Sent as |
|---|---|
| a String | itself |
| a class or module (`self` inside a class body is that class) | its Ruby source, including bodies that reopen it in other files (see the limits below) |
| a method (`instance_method(:call)`, `AcmeParser.method(:parse)`) | that method's source |
| a Proc | evaluated against the instance on each call; it can return any of the above, an Array of them, or `nil`/`false` to add nothing (`-> { strict? && "Be strict." }`) |

```ruby
class InvoiceParser
  include Squishling

  append_to_purpose "The Ruby that parses well-formed invoices:", self, AcmeParser
  append_to_purpose -> { "This client's invoices are in #{currency}." }

  squish :summarize, append_to_purpose: false do   # no appendices for this method
    string :summary
  end
end
```

The same option goes in the class-wide call: `squishling append_to_purpose: ["...", self]`.

Sections are added down the chain: class, then subclass, then `squish :name, append_to_purpose:`, then
`squish!(append_to_purpose:)`. `false` drops everything declared above it, so `[false, "Only this."]`
replaces it.

Source is read with Ruby's own parser (Prism) the first time it's needed and cached. Some limits:

- A class's source is every `class`/`module` body that defines one of its methods, plus the one where its
  constant is first assigned (including `Parser = Class.new do ... end`). A body that reopens the class
  without defining a method isn't included.
- A class without a constant (built with `Class.new` and never assigned, nested in an anonymous module, or given
  a temporary name) is sent method by method: each of its own `def`s, without the code around them.
- A class built from a `Struct.new`/`Data.define` block (`Point = Struct.new(:x) do ... end`) isn't found; reopen
  it with `class Point` or append its methods individually.
- Only `def`s count. Methods made with `define_method` or `attr_*` aren't shown, and a method item made that way
  raises `ConfigurationError`, as does code with no source file, such as code generated by `eval`.

**Appended source is sent to your provider.** Don't append classes that hold secrets in constants.

## What the LLM sees

- **System prompt:** your purpose (a String, or a Proc evaluated against the instance), then any
  `append_to_purpose` sections, then a short note describing the input format.
- **User message:** JSON with the method's arguments, mapped to their parameter names. Any
  `squish_context` values, and a `squish!` call's `context:`, go under `"context"`:

```json
{ "arguments": { "ticket_text": "API is down!" },
  "context":   { "customer_tier": "enterprise", "product": "API" } }
```

- **Retries and escalation:** another attempt of the same step gets the validation errors in the same conversation. A
  later [escalation](configuration.md#models-and-escalation) step, which may be a different provider (say, local
  Ollama, then hosted Anthropic Claude), gets the same JSON plus the previous model's rejected output and the
  errors, including any messages your [`squish_validate`](failures.md#output-checks-squish_validate) check
  returned. The rejected output is model-generated and is truncated to 4,000 characters; set
  `forward_rejected: false` on a step to start it from the original input only, without the rejected output or
  its errors. Don't put data in those messages that you wouldn't send as an argument.

`squish_context` names are read from a method of that name if there is one, otherwise from the instance
variable. Only context you name is sent. Instance variables are never dumped wholesale, so API clients,
database connections, and secrets stay out of the prompt.
