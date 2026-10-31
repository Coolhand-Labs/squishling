# Adapters

An **adapter** is how Squishling reaches a model. Squishling builds the request (system prompt, conversation so far,
strict output schema, generation params), the adapter makes one completion and returns the model's output, and
Squishling does the rest: validation, `squish_validate`, retries and escalation, harnesses, `squawk`, and fallbacks.
Two adapters ship, and you can write your own.

| Adapter | Reaches | Needs |
|---|---|---|
| [`:ruby_llm`](#ruby_llm) | OpenAI, Anthropic Claude, Google Gemini, AWS Bedrock, OpenRouter, and every provider [RubyLLM](https://rubyllm.com) supports | `gem "ruby_llm"` |
| [`:openai_compatible`](#openai-compatible-endpoints) | Any server that speaks OpenAI's Chat Completions API: OpenAI, Ollama, vLLM, LM Studio, llama.cpp, Together, Groq, … | nothing (Ruby's `Net::HTTP`) |
| [Your own](#writing-your-own) | Anything | a class with one method |

Squishling itself depends on neither RubyLLM nor any provider SDK.

## Choosing one

```ruby
Squishling.configure do |config|
  config.adapter = :ruby_llm                    # a built-in or registered adapter, by name
  # config.adapter = { type: :openai_compatible, base_url: "http://localhost:11434/v1", default_model: "llama3.2" }
  # config.adapter = MyAdapter.new              # or any adapter instance
end
```

An adapter is built when you assign it, so a missing gem or a bad option fails at boot, not on the first request.
There is one adapter per process; every squishling class, method, and escalation step goes through it.

**When you set none**, Squishling uses the RubyLLM adapter if the `ruby_llm` gem is in your bundle, so apps that
configured RubyLLM before adapters existed keep working. Squishling no longer requires `ruby_llm` when it loads, so an
app that doesn't load its Gemfile with `Bundler.require` should `require "ruby_llm"` before `RubyLLM.configure`. Without the gem, the first squished call
raises `Squishling::ConfigurationError` saying what to add.

## `:ruby_llm`

Everything works as it did before adapters: configure provider API keys with `RubyLLM.configure`, name models, and
use `provider:` for models missing from RubyLLM's registry. See [Configuration](configuration.md). Transport-level
retries are RubyLLM's (`RubyLLM.config.max_retries`, `request_timeout`).

| Option | Default | Description |
|---|---|---|
| `keep_cause` | `false` | RubyLLM's exception holds the provider's response body, which can echo your request, and error trackers report the whole `cause` chain. By default the errors the adapter raises carry a sanitized `cause` (the class and HTTP status only). `true` keeps RubyLLM's original exception there. See [the cause of a provider failure](failures.md#the-cause-of-a-provider-failure). |

**Failures** are sorted by the HTTP status of the error's response, the same way as for the OpenAI-compatible adapter
below (an error with no response, such as a timeout, is sorted by its class). RubyLLM's own error classes are not what
decides: on a 400 its middleware picks a class from the provider's message text, so a bad parameter whose message says
"per day" would otherwise look like a rate limit. The one RubyLLM class that is honored over the status is
`RubyLLM::ContextLengthExceededError`, an `LLMError`, since RubyLLM is where each provider's wording for an overlong
prompt is known. RubyLLM picks that class from the message on a 400, with wording broader than the OpenAI-compatible
adapter's, so a bad parameter whose message happens to match is retried as an overflow rather than rejected. Each of
these errors carries a sanitized `cause` (see `keep_cause` above).

This is the only built-in adapter that supports `type: :judgment` judges ([System One decision models](harnesses.md#the-judge)).

## OpenAI-compatible endpoints

```ruby
Squishling.configure do |config|
  config.adapter = {
    type: :openai_compatible,
    base_url: "http://localhost:11434/v1",   # where /chat/completions lives
    api_key: ENV["LLM_API_KEY"],             # optional for local servers
    default_model: "llama3.2"                # for steps that name no model
  }
  config.default_model = "llama3.2"
end
```

| Option | Default | Description |
|---|---|---|
| `base_url` | `https://api.openai.com/v1` | The API root. Requests go to `{base_url}/chat/completions`. Must be `http(s)` and carry no credentials, query, or fragment. |
| `api_key` | `ENV["OPENAI_API_KEY"]` for OpenAI's own endpoint, else none | A String, or a callable returning one (called once per completion, outside the adapter's retry handling, so rotating keys work and its exceptions reach you unchanged). Sent as a bearer token; omitted when blank. The key is sent as-is, so use `https://` for anything off your machine or trusted network. `OPENAI_API_KEY` is read only for OpenAI's own `https://api.openai.com`, so it can never go to another host: pass `api_key:` for any other endpoint that needs one. |
| `headers` | `{}` | Extra request headers, e.g. `{ "OpenAI-Organization" => "org-…" }` or a gateway's own. |
| `default_model` | `nil` | The model for steps that don't name one. Without it, a step with no model raises `ConfigurationError`. |
| `open_timeout` / `read_timeout` | `10` / `120` | Seconds. |
| `max_retries` | `2` | Timeouts, connection and protocol failures, HTTP 408, 429, and 5xx are retried this many times with exponential backoff (honoring `Retry-After`, up to 30 seconds) before they surface as an `LLMError`. A timed-out request may still have been processed by the server, so a retry can be billed twice; set `max_retries: 0` if that matters more than resilience. |
| `max_tokens_param` | `:max_completion_tokens` | The body key for `max_output_tokens`. Use `:max_tokens` for servers that don't know the newer name. |
| `structured_output` | `:json_schema` | `:json_schema` asks for strict structured output. For servers without it use `:json_object`, or `:none`: the schema then goes into the system prompt in words. Squishling validates every answer itself either way. |

**Credentials stay out of serializers.** The adapter holds the `api_key` and the `headers` (which may carry an
`api-key` or `Authorization` value) in an opaque wrapper, not in plain instance variables, so logging or caching the
adapter or `Squishling.config` can't write them out: `inspect`, `to_s`, `pp`, `to_yaml`, `as_json` (including
ActiveSupport's `instance_values` walk) and `to_json` show `[REDACTED]`, and `Marshal.dump` raises a `TypeError`
instead of dumping the key. This guards against accidental serialization (a logged config, an error tracker, a cache
dump), not against code running in your process, which can still reach the value. If you write your own adapter,
keep credentials out of plain instance variables the same way, or define `encode_with`, `as_json`, and
`marshal_dump` to omit them.

**How params map.** `temperature` → `temperature`; `max_output_tokens` → `max_tokens_param`; `thinking: { effort: }` →
`reasoning_effort` (`true`/`false` leave the model's default, and a `budget:` or `display:` raises
`ConfigurationError`, since Chat Completions has no field for them). Any other param (`top_p`, `seed`, …) goes into
the request body as given. Squishling's own keys (`model`, `messages`, `response_format`, `n`, `stream`) always win.
`provider:` has no meaning here and is ignored.

**Failures.** The HTTP status decides (see [the status mapping](#the-error-contract)): 408, 413, 429, 5xx, timeouts, and
connection errors raise `LLMError` once the adapter's own retries are used up; 401, 402, 403, 404, and a redirect raise
`ConfigurationError`; any other 4xx (400, 409, 422, …) raises `RequestRejectedError`, never retried or escalated. The
one exception is a 400 that reports an overlong context, which is an `LLMError` too, since it depends on the input (a
bigger model may take it). This adapter recognizes one when the error's `code` or `type` is `context_length_exceeded`, or,
for servers that send neither (vLLM, Ollama, llama.cpp), when its message uses the usual wording ("context length",
"context window", "context size", "too many tokens", "prompt is too long"). The message is only matched against that
wording, never repeated; the match is deliberately narrow, so a wording it doesn't know is a rejected request, not a
retry. Messages carry the status or error class only; a rejected request also carries the server's error status and code
when they are plain tokens (as `provider_status` and `provider_code`). The server's message, the response body, and the
API key never appear in an error or log. Redirects aren't followed, so the key can't be sent to another host.

## Writing your own

Subclass `Squishling::Adapter::Base`, implement `complete`, and return a `Squishling::Adapter::Response`:

```ruby
class AcmeAdapter < Squishling::Adapter::Base
  def initialize(client: Acme::Client.new)
    super()
    @client = client
  end

  def complete(request)
    reply = @client.chat(
      model: request.model,
      system: request.instructions,
      messages: request.messages,                 # [{ role: :user | :assistant, content: "…" }, …]
      json_schema: request.schema["schema"],      # strict; Squishling validates the answer regardless
      **request.params
    )
    Squishling::Adapter::Response.new(
      content: reply.text,                        # the raw String (or a Hash you already parsed)
      model: reply.model,
      tokens: { input_tokens: reply.usage.in, output_tokens: reply.usage.out }
    )
  rescue Acme::AuthError
    raise configuration_error(request, "Acme rejected the credentials")
  rescue Acme::HTTPError => e
    # sorted by status like the built-in adapters; only the status and a rejection's status/code tokens are repeated
    raise http_failure(request, status: e.status, body: e.response_body, via: "Acme, HTTP #{e.status}")
  rescue Acme::Error => e
    raise llm_error(request, "Acme failed (#{e.class})")
  end

  private

  # Optional: what an overlong prompt looks like for Acme. The default (super) already recognizes a 400 whose error
  # code or type is "context_length_exceeded"; add whatever else Acme's errors tell you, without reading its message.
  # body is the provider's error body, a JSON String or a Hash (or nil); ErrorBody.error reads either safely.
  def context_length?(status:, body:)
    super || (status == 400 && Squishling::Adapter::ErrorBody.error(body)&.[]("code") == "prompt_too_long")
  end
end

Squishling.configure { |config| config.adapter = AcmeAdapter.new }
# or register it by name, to use config.adapter = :acme (or { type: :acme, client: … }):
Squishling.register_adapter(:acme, AcmeAdapter)
```

### The request

`Squishling::Adapter::Request` carries everything for one completion:

| Field | |
|---|---|
| `label` | `"Class#method"`, to prefix your error messages (the `configuration_error` / `llm_error` helpers do; `http_failure(request, status:, body:, via:)` sorts an HTTP failure; `rejected_request_error(request, via:, body:, http_status:)` builds the error for a rejected request, from a JSON String or String-keyed Hash body). |
| `model`, `provider` | The escalation step's, or `nil` when it names none (use your own default). What `provider:` means is up to you. |
| `instructions` | The system prompt. |
| `messages` | The conversation so far, ending with the user message to answer. After invalid output, Squishling appends your previous answer and a retry message; you never keep history. |
| `schema` | `{ "name", "description", "schema", "strict" => true }`: the strict structured-output payload, without the conditional keywords providers can't take. |
| `params` | The resolved [generation params](configuration.md#generation-params): the portable `:temperature`, `:max_output_tokens`, `:thinking`, plus provider-specific keys. Squishling has already rejected the keys it owns. Translate the portable ones for your provider; pass the rest through if it takes them. |

### The response

`Squishling::Adapter::Response.new(content:, model:, tokens:, finish_reason:)`. `content` is the model's output as a
String, or a Hash if you parsed it; `nil` or empty counts as invalid output and is retried. `model` is the id the
provider reports. `tokens` is a Hash (`:input_tokens`, `:output_tokens`, and anything else you have); `{}` when
unknown. These feed [`squawk`'s `usage`](failures.md#observing-every-attempt-squawk), the [observer](observers.md)'s `Usage`, and the
[token budget](failures.md#capping-a-calls-cost-token-budgets), which counts `:input_tokens` and `:output_tokens`
(a response with none never exhausts a budget).
`finish_reason` is why the provider stopped, as a Symbol: `:stop`, `:max_tokens` (the output cap cut the reply off),
`:content_filter`, `:tool_calls`, or the provider's own spelling; leave it out (`nil`) when unknown. Map your
provider's "length" reason to `:max_tokens`, so Squishling can [tell a cutoff from a wrong
answer](failures.md#a-cutoff-or-a-wrong-answer).

### The error contract

Classifying a provider failure is the adapter's job; what happens next is Squishling's.

**An adapter defines** which error a failure is. Only the adapter knows its provider's status codes, error bodies, and
how it says a prompt is too long:

| Raise | When | What Squishling does |
|---|---|---|
| `Squishling::ConfigurationError` | Bad credentials, billing, an unknown model or endpoint: anything a retry can't fix | Raised at once. Never retried, escalated, or sent to `squish_fallback`. |
| `Squishling::RequestRejectedError` (a `ConfigurationError`) | The provider refused the request itself: a 400 or another 4xx for a bad param or schema | Same as `ConfigurationError`, so a setup mistake can't be hidden by a fallback on every call. |
| `Squishling::LLMError` | Rate limit, 5xx, timeout, connection failure, an overlong context: anything worth another go | Moves to the next attempt; raised from the last one (and goes to `squish_fallback`). |

**Squishling manages** everything that follows from the class: retries, escalation, the fallback, the token budget, and
`squawk`. It never looks at a provider's status, code, or message; it sees only the error class your adapter raised.

For an HTTP provider, `http_failure(request, status:, body:, via:)` does the sorting, so every adapter treats a status
the same way: 408, 413, 429, 5xx, no status at all (a timeout), and a success status (a reply that was unusable) are
`LLMError`s; 401, 402, 403, 404, and a redirect are `ConfigurationError`s;
every other 4xx is a `RequestRejectedError`. `via` ("Acme, HTTP 400") is the only text repeated, plus the status and
code tokens of a rejection. Between those, one case depends on the provider: a rejected request whose input was too
long for the model should be an `LLMError`, since a bigger model may take it. `http_failure` asks the
`context_length?(status:, body:)` hook. Its default recognizes a 400 whose error `code` or `type` is
`context_length_exceeded` and never reads the message; override it (calling `super`) to recognize what your provider
sends. Where the adapter can't tell, leave it: the failure stays a `RequestRejectedError`, which is never absorbed.

Keep the provider's own message out of every error you raise: it can echo request content or part of a key, and ours
reach logs and error trackers, and so do trackers that walk the `cause` chain. If the provider's exception carries a
response body (an HTTP client error), don't leave it as the `cause` that raising inside a `rescue` sets: pass
`cause: sanitized_cause(error, status: …)`, which builds a stand-in with only the class, the status, and the
backtrace. An exception that carries no body (a timeout, a refused connection) can stay as the `cause`. Any other
exception propagates unwrapped and is never retried, so map your transport's errors. Return anything but an
`Adapter::Response` and Squishling raises `ConfigurationError`.

### Optional hooks

- **`judgments?` and `judge(input, questions:, step:, label:)`**: System One decision models for `type: :judgment` judges.
  `judge` returns an object answering `[:winner]` with something that responds to `choice` and `probabilities`.
  Without `judgments?`, such a judge raises `ConfigurationError` before any request. If the object has `tokens` (with
  `input` and `output` readers), they count toward the call's token budget.
- **`capture_context` and `with_context(context) { … }`**: samples (the `:squishsum` harnesses) send their requests from
  worker threads. `capture_context` runs on the caller's thread and returns whatever your tracing needs; `with_context`
  re-establishes it around each worker's request. The RubyLLM adapter uses this for its instrumentation workflow.

### Thread safety

Adapters are called concurrently from worker threads when a harness takes samples. Keep no unsynchronized mutable
state (a per-request HTTP connection, as the OpenAI-compatible adapter does, is the simple way).

### Testing against your adapter

To test your *application* (not an adapter), use [`squishling/testing`](testing.md): a scripted adapter with request
inspection, call assertions, and stubs. To unit-test an adapter you wrote, a canned one is enough:

```ruby
class CannedAdapter < Squishling::Adapter::Base
  def initialize(*replies) = (@replies = replies)

  def complete(request)
    Squishling::Adapter::Response.new(content: @replies.shift, model: request.model, tokens: {})
  end
end

Squishling.configure { |config| config.adapter = CannedAdapter.new({ "label" => "bug" }) }
```
