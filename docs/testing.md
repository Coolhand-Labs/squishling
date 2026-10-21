# Testing

`require "squishling/testing"` adds test support: a scripted [adapter](adapters.md) that answers in place of a
provider and records what was sent to it, stand-ins for the callers of squished methods, replies derived from an output
schema, and assertions. It is opt-in (`require "squishling"` doesn't load it), needs no test framework or mocking
library, and works with RSpec (without rspec-mocks), Minitest, and Mocha alike. It makes no network request.

```ruby
# Minitest
include Squishling::Testing::Minitest

# RSpec
RSpec.configure { |config| config.include Squishling::Testing::RSpec }
```

Both give your tests the helpers below and put back, after each test, whatever the helpers changed
(`Squishling::Testing.reset!`). They touch only the adapter, observer, and stubs they installed (and only while they
still hold what the helpers set), so the rest of your `Squishling.configure` survives.

The helpers change global state (`Squishling.config` and the stubbed classes), so tests that use them must not run
in parallel threads.

## Scripting the model

```ruby
fake = fake_squishling do |llm|
  llm.step("gemini-2.5-flash").reply({ regex: "[bad(" }, { regex: "Run.*" })  # in order; the last one repeats
  llm.step("gemini-2.5-pro").fail(:rate_limit)
  llm.step(:any).reply({ regex: "fallback.*" })                               # anything no rule above claims
end

result = RegexInferrer.call(sample_turns: turns)

assert_equal "Run.*", result.regex
assert_equal 2, fake.requests.size
assert_sent_arguments fake, { sample_turns: turns }       # what left the process
assert_includes fake.requests.last.errors, "regex is not a valid Ruby regex"   # the re-ask carried them
```

A reply is one of:

| Reply | The model… |
|---|---|
| a `Hash` | answered with this object |
| a `String` | returned this text (malformed or fenced JSON, truncated output) |
| `nil` | returned nothing (a refusal or a cut-off) |
| `Squishling::Testing::Reply.new(content, model: "m", usage: { input_tokens: 10, output_tokens: 3 })` | answered, and the provider reported this model and these token counts (`squawk`'s `metadata[:usage]`, the observer's `Usage`) |
| an `Exception` | made the request raise it |
| `.fail(intent)` | the provider failed: see below |

`reply` takes several, `.fail` adds one, and `.once` makes running out of replies an error instead of repeating the last.

**Provider failures by intent.** You don't need to know which SDK error maps to which Squishling error:

| Intent | Raises |
|---|---|
| `:rate_limit`, `:server_error`, `:overloaded`, `:timeout`, `:context_length` | `LLMError` (the next attempt is tried) |
| `:bad_request`, `:unauthorized`, `:forbidden` | `ConfigurationError` (never retried, never given to a fallback) |

**Selecting what a rule answers.** `step(model)`, `step(provider: :vertexai)`, and `step(:any)` answer escalation
attempts; `attempt: 2` narrows a step rule to one attempt of the escalation. Rules are matched most specific first
(a sample or the judge, then the rule naming the most of model, provider and attempt, then `step(:any)`), and by
declaration order within that.
Scripts are keyed by model, so a rotated tier (`priority:`) gets the same answers whichever model goes first. Which
model goes first still depends on how many calls the class has had, so don't assert the order of `fake.models` for a
rotated tier unless the class is new to the test (or pin the tier with `rotate: false`).
A request no rule covers raises `Squishling::Testing::UnscriptedRequestError` naming the squished method; it isn't
a `Squishling::Error`, so `squish_fallback` can't hide it.

### Harnesses

```ruby
fake_squishling do |llm|
  llm.sample("a").reply(valid_reply_for(Triager))
  llm.sample("b").reply(valid_reply_for(Triager, team: "billing"))
  llm.judge.verdict(:a, reason: "a fits")                    # a chat judge
  llm.judge.judgment(:b, confidence: 0.92)                   # a System One judge (type: :judgment, min_confidence:)
  llm.judge.fail_judgment(:timeout)
end
```

Each sample has its own script, so the order its worker thread happens to run in can't change what it gets. The
scripts, the request log, and the conversation tracking are taken under one lock. `DisagreementError#candidates`
and `#verdict` are the real ones; rescue them as you would in production.

## Inspecting what was sent

`fake.requests` is every provider request, in order, as `Squishling::Testing::Request`:

| | |
|---|---|
| `arguments`, `context` | the method's arguments and the `squish_context` / `squish!` context the model was sent |
| `system_prompt`, `output_schema` | the purpose (with `append_to_purpose` sections) and the strict schema |
| `model`, `provider`, `params` | the step it went to |
| `role`, `sample`, `attempt`, `attempts` | `nil`/`:sample`/`:judge`, `"a"`, and where it is in the escalation |
| `conversation` | the chat it belongs to |
| `errors` | the validation messages a retry or escalation carried back to the model |
| `forwarded_rejected` | the rejected output forwarded to the next step (`nil` with `forward_rejected: false`) |
| `candidates` | for a judge, the two samples |
| `messages`, `reply`, `failed?` | the conversation as sent, and the `Adapter::Response` (or error) that came back |

`fake.conversations` groups the requests by chat: a retry on the same step shares one, and an escalation to a new
step starts a new one. `fake.requests_for(sample: "a")`, `fake.models`, and `fake.arguments` are shortcuts.

## Asserting the LLM was not called

```ruby
assert_no_llm_call { RegexInferrer.call(sample_turns: easy_turns) }   # then: refute result.squished?
assert_llm_calls fake, 2
```

`assert_no_llm_call` fails even if the code under test rescued the error that stopped the call.

**A safety net for the whole suite.** In a suite-wide `before` hook, `forbid_provider_calls!` makes any request that
reaches the provider raise `ProviderCallError` naming the squished method (`"RegexInferrer#call reached the provider…"`),
so a missing script fails at the call, not far from it. Installing a fake replaces it.

## Stubbing a squished class for its callers

Callers of a squished class shouldn't run Squishling at all. These make `Klass.call` return a real, schema-validated
typed result, or raise the real error class, without `allow(...).to receive`:

```ruby
stub_squishling_result(PatternGenerator, regex: "x")                          # squished? is true
stub_squishling_result(PatternGenerator, { regex: "x" }, squished: false)     # as the Ruby path would return it
stub_squishling_result(PatternGenerator, regex: "x") { ... }                  # for the block only

stub_squishling_error(PatternGenerator, :invalid_output, errors: ["bad"], raw: "{}", attempts: 2, models: %w[a b])
stub_squishling_error(PatternGenerator, :llm_error)           # also :configuration, :disagreement (candidates:, verdict:, reason:)
```

Attributes that don't satisfy the method's `output_schema` raise `Squishling::Testing::SetupError` when you stub, so a
stand-in can't drift from the real result type. Pass `method: :triage` for another squished method. The stubs are
removed after each test. A stub applies to that class only, not to its subclasses, which keep their own behavior. The
hook that makes a stub possible stays on the class for the life of the process, so stub the classes of your suite, not
one per test.

## Running parts of a method without a model

```ruby
squishling_validate(Klass, { "regex" => "[bad(" }, text: "x")   # => ["regex is not a valid Ruby regex"]
squishling_fallback_for(Klass, Squishling::LLMError.new("x"), text: "x")   # the typed fallback result
squishling_preview(Klass, text: "x")
# => { system_prompt:, user_message:, output_schema:, step: }   # for snapshot tests; makes no request
```

Arguments are keywords, or `args: [...]` for positional ones; `receiver:` supplies an instance for a class whose
constructor takes arguments; `method:` names a squished method other than `call`. (A squished method with a parameter
called `args`, `receiver`, or `method` can't be given it as a keyword here.) `squishling_preview` doesn't advance model rotation.

## Replies derived from the schema

```ruby
valid_reply_for(Triager)                                  # => { "priority" => "example", "team" => "example" }
valid_reply_for(Triager, team: "billing")                 # overrides
invalid_reply_for(Triager, violating: :score)             # out of its range, enum, or type
invalid_reply_for(Triager, violating: :score, how: :missing)   # :enum, :range, :type, :null, :missing
```

Both accept a squished class, a `Squishling::Schema`, or a schema Hash, and are checked against the schema before they
are returned, so a test that doesn't care about the content stays valid when the schema changes. A schema it can't
satisfy on its own (a `pattern`, an unsatisfiable conditional) raises `SetupError` and asks for overrides.

## `squawk` and observers

```ruby
capture = with_squawk(capture_squawk) { Klass.call(text: "x") }
capture.calls.map { |call| call.metadata[:attempt] }    # output:, error:, and metadata: of every attempt
```

`with_squawk` swaps `config.squawk` for the block and puts the previous hook back, so an app-wide hook that enqueues
a job isn't run in tests. A `squawk:` set on a class or method still takes precedence over the configured one.

An observer you configured *before* `fake_squishling` keeps working while the fake is installed (it is chained behind
the fake's own). Configure it first: one assigned afterwards replaces the fake's, and then sample and judge scripts
can't tell which request is which.

## How it works

`fake_squishling` assigns a `Squishling::Testing::Adapter` (a `Squishling::Adapter::Base`) as `config.adapter`, and an
observer that tells it which role, sample, and attempt each request is. Because it sits behind the same interface as
the real adapters, it needs no knowledge of RubyLLM or any provider, and it is covered by Squishling's own specs.
Call `Squishling::Testing.install` and `.reset!` yourself if you use a test framework other than the two above.
