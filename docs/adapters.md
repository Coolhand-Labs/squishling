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

**How params map.** `temperature` → `temperature`; `max_output_tokens` → `max_tokens_param`; `thinking: { effort: }` →
`reasoning_effort` (`true`/`false` leave the model's default, and a `budget:` or `display:` raises
`ConfigurationError`, since Chat Completions has no field for them). Any other param (`top_p`, `seed`, …) goes into
the request body as given. Squishling's own keys (`model`, `messages`, `response_format`, `n`, `stream`) always win.
`provider:` has no meaning here and is ignored.

**Failures.** Every HTTP status of 300 or above except 408, 429, and 5xx (401, 403, 404, 400, 422, a redirect, …) raises `ConfigurationError` (never retried or escalated; a 400 that
reports an overlong context, and a 413, are `LLMError`s, since they depend on the input; a 400 counts as an overlong
context when its error code is `context_length_exceeded` or its message uses the usual wording ("context length", "too many
tokens", …), which the message is only matched against, never repeated). 408, 429, 5xx, timeouts, and
connection errors raise `LLMError` once the adapter's own retries are used up. Messages carry the status or error
class only; the server's message, the response body, and the API key never appear in an error or log. Redirects
aren't followed, so the key can't be sent to another host.

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
  rescue Acme::Error => e
    raise llm_error(request, "Acme failed (#{e.class})")
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
| `label` | `"Class#method"`, to prefix your error messages (the `configuration_error` / `llm_error` helpers do). |
| `model`, `provider` | The escalation step's, or `nil` when it names none (use your own default). What `provider:` means is up to you. |
| `instructions` | The system prompt. |
| `messages` | The conversation so far, ending with the user message to answer. After invalid output, Squishling appends your previous answer and a retry message; you never keep history. |
| `schema` | `{ "name", "description", "schema", "strict" => true }`: the strict structured-output payload, without the conditional keywords providers can't take. |
| `params` | The resolved [generation params](configuration.md#generation-params): the portable `:temperature`, `:max_output_tokens`, `:thinking`, plus provider-specific keys. Squishling has already rejected the keys it owns. Translate the portable ones for your provider; pass the rest through if it takes them. |

### The response

`Squishling::Adapter::Response.new(content:, model:, tokens:)`. `content` is the model's output as a String, or a Hash if
you parsed it; `nil` or empty counts as invalid output and is retried. `model` is the id the provider reports.
`tokens` is a Hash (`:input_tokens`, `:output_tokens`, and anything else you have); `{}` when unknown. These feed
[`squawk`'s `usage`](failures.md#observing-every-attempt-squawk) and the [observer](observers.md)'s `Usage`.

### The error contract

| Raise | When | What Squishling does |
|---|---|---|
| `Squishling::ConfigurationError` | Bad credentials, a request the provider rejects, an unknown model: anything a retry can't fix | Raised at once. Never retried, escalated, or sent to `squish_fallback`. |
| `Squishling::LLMError` | Rate limit, 5xx, timeout, connection failure, an overlong context: anything worth another go | Moves to the next attempt; raised from the last one (and goes to `squish_fallback`). |

Keep the provider's own message out of both: it can echo request content or part of a key, and ours reach logs and
error trackers. Put the original on `cause` (raising inside a `rescue` does that for you). Any other exception
propagates unwrapped and is never retried, so map your transport's errors. Return anything but an
`Adapter::Response` and Squishling raises `ConfigurationError`.

### Optional hooks

- **`judgments?` and `judge(input, questions:, step:, label:)`**: System One decision models for `type: :judgment` judges.
  `judge` returns an object answering `[:winner]` with something that responds to `choice` and `probabilities`.
  Without `judgments?`, such a judge raises `ConfigurationError` before any request.
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
