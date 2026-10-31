# frozen_string_literal: true

require "webmock/rspec"

RSpec.describe Squishling::Adapters::OpenAICompatible do # rubocop:disable RSpec/SpecFilePathFormat -- openai_compatible, not open_ai
  let(:url) { "https://api.openai.com/v1/chat/completions" }
  let(:options) { { api_key: "sk-test", max_retries: 0 } }
  let(:adapter) { described_class.new(**options) }

  def completion(content = '{"label":"ok"}', **extra)
    { model: "gpt-test-2026", choices: [{ index: 0, message: { role: "assistant", content: }, finish_reason: "stop" }],
      usage: { prompt_tokens: 12, completion_tokens: 4 } }.merge(extra)
  end

  def reply(body = completion, status: 200, headers: {})
    { status:, body: body.is_a?(String) ? body : JSON.generate(body),
      headers: { "Content-Type" => "application/json" }.merge(headers) }
  end

  def stub_post(**with)
    stub = stub_request(:post, url)
    with.empty? ? stub : stub.with(**with)
  end

  def sent_body
    JSON.parse(WebMock::RequestRegistry.instance.requested_signatures.hash.keys.last.body)
  end

  it "reports the first choice's finish reason, with \"length\" as :max_tokens" do
    stub_post.to_return(reply(completion("", choices: [{ message: { content: "" }, finish_reason: "length" }])),
      reply(completion), reply(completion("{}", choices: [{ message: { content: "{}" } }])))

    reasons = Array.new(3) { adapter.complete(adapter_request).finish_reason }

    expect(reasons).to eq([:max_tokens, :stop, nil])
  end

  it "is registered as :openai_compatible, built from a Hash of options" do
    built = Squishling::Adapter.build({ type: :openai_compatible, base_url: "http://localhost:11434/v1" }, "test")

    expect(built).to be_a(described_class)
    expect(Squishling.adapters).to include(:openai_compatible)
  end

  it "shows only where requests go when inspected, never the key or header values" do
    shown = described_class.new(api_key: "sk-secret", headers: { "X-Key" => "hdr-secret" }, default_model: "m").inspect

    expect(shown).to eq("#<Squishling::Adapters::OpenAICompatible https://api.openai.com/v1/chat/completions " \
                        'default_model="m" structured_output=:json_schema>')
    expect(shown).not_to include("secret")
    expect(Squishling.config.tap { |c| c.adapter = { type: :openai_compatible, api_key: "sk-secret" } }.inspect)
      .not_to include("sk-secret")
  end

  describe "serializing the adapter" do
    let(:secret_adapter) do
      described_class.new(api_key: "sk-SECRETKEY", headers: { "api-key" => "hdr-SECRETHEADER" }, default_model: "m")
    end

    # What ActiveSupport's Object#as_json does (it is not a dependency): walk the instance variables.
    def instance_values_json(object)
      object.instance_variables.to_h do |name|
        value = object.instance_variable_get(name)
        [name.to_s.delete_prefix("@"), value.respond_to?(:as_json) ? value.as_json : value.to_s]
      end
    end

    it "keeps the key and header values out of to_yaml, also through the configuration" do
      Squishling.configure { |config| config.adapter = secret_adapter }

      [secret_adapter.to_yaml, Squishling.config.to_yaml].each do |yaml|
        expect(yaml).not_to include("SECRETKEY")
        expect(yaml).not_to include("SECRETHEADER")
      end
    end

    it "refuses Marshal.dump without echoing the key" do
      expect { Marshal.dump(secret_adapter) }.to raise_error(TypeError) { |error|
        expect(error.message).not_to include("SECRET")
      }
    end

    it "keeps the key out of inspect, pp, to_s, interpolation, and an instance_values-style JSON walk" do
      shown = [secret_adapter.inspect, secret_adapter.pretty_inspect, secret_adapter.to_s, "key #{secret_adapter}",
               JSON.generate(instance_values_json(secret_adapter))]

      expect(shown.join).not_to include("SECRET")
      expect(instance_values_json(secret_adapter).values).to include("[REDACTED]")
    end

    it "holds no instance variable that is the key, a header value, or the headers themselves" do
      values = secret_adapter.instance_variables.map { |name| secret_adapter.instance_variable_get(name) }

      expect(values.grep(String)).not_to include("sk-SECRETKEY")
      expect(values.grep(Hash).flat_map(&:values)).not_to include("hdr-SECRETHEADER")
    end

    it "still sends the key and headers" do
      stub = stub_post(headers: { "Authorization" => "Bearer sk-SECRETKEY", "api-key" => "hdr-SECRETHEADER" })
        .to_return(reply)

      secret_adapter.complete(adapter_request)

      expect(stub).to have_been_requested
    end
  end

  describe "credential headers" do
    it "sends a callable's or the environment's key" do
      from_proc = stub_post(headers: { "Authorization" => "Bearer from-proc" }).to_return(reply)
      from_env = stub_post(headers: { "Authorization" => "Bearer from-env" }).to_return(reply)

      described_class.new(api_key: -> { "from-proc" }, max_retries: 0).complete(adapter_request)
      with_env("OPENAI_API_KEY" => "from-env") { described_class.new(max_retries: 0).complete(adapter_request) }

      expect(from_proc).to have_been_requested
      expect(from_env).to have_been_requested
    end

    it "sends no Authorization header for a blank key" do
      stub = stub_post.with { |req| !req.headers.key?("Authorization") }.to_return(reply)

      described_class.new(api_key: "  ", max_retries: 0).complete(adapter_request)

      expect(stub).to have_been_requested
    end
  end

  it "doesn't support judgments" do
    expect(adapter.judgments?).to be(false)
  end

  describe "#complete" do
    it "posts a strict json_schema request to {base_url}/chat/completions with the key as a bearer token" do
      stub = stub_post(headers: { "Authorization" => "Bearer sk-test", "Content-Type" => "application/json" })
        .to_return(reply)

      response = adapter.complete(adapter_request)

      expect(stub).to have_been_requested
      expect(sent_body).to eq(
        "model" => "gpt-test", "n" => 1, "stream" => false,
        "messages" => [{ "role" => "system", "content" => "Classify." }, { "role" => "user", "content" => "hi" }],
        "response_format" => { "type" => "json_schema",
                               "json_schema" => { "name" => "response", "schema" => adapter_request.schema["schema"],
                                                  "strict" => true } }
      )
      expect(response).to be_a(Squishling::Adapter::Response)
      expect(response.content).to eq('{"label":"ok"}')
      expect(response.model).to eq("gpt-test-2026")
      expect(response.tokens).to eq(input_tokens: 12, output_tokens: 4)
    end

    it "sends the whole conversation, with assistant turns" do
      stub_post.to_return(reply)
      messages = [{ role: :user, content: "a" }, { role: :assistant, content: "bad" },
                  { role: :user, content: "again" }]

      adapter.complete(adapter_request(messages:))

      expect(sent_body["messages"].map { |m| m["role"] }).to eq(%w[system user assistant user])
    end

    it "names the schema, sanitized, when it has a name" do
      stub_post.to_return(reply)
      named = adapter_request.schema.merge("name" => "Ticket triage!", "description" => "Triage")

      adapter.complete(adapter_request(schema: named))

      expect(sent_body.dig("response_format",
        "json_schema")).to include("name" => "Ticket_triage_", "description" => "Triage")
    end

    it "parses token details when the server reports them" do
      usage = { prompt_tokens: 20, completion_tokens: 9, prompt_tokens_details: { cached_tokens: 8 },
                completion_tokens_details: { reasoning_tokens: 3 } }
      stub_post.to_return(reply(completion(usage:)))

      expect(adapter.complete(adapter_request).tokens)
        .to eq(input_tokens: 20, output_tokens: 9, cache_read_tokens: 8, thinking_tokens: 3)
    end

    it "falls back to the requested model and no tokens when the server reports neither" do
      stub_post.to_return(reply({ choices: [{ message: { content: "{}" } }] }))

      response = adapter.complete(adapter_request)

      expect(response).to have_attributes(model: "gpt-test", tokens: {})
    end

    it "joins content parts, for servers that return an array" do
      parts = [{ type: "text", text: '{"label":' }, { type: "text", text: '"ok"}' }]
      stub_post.to_return(reply(completion(parts)))

      expect(adapter.complete(adapter_request).content).to eq('{"label":"ok"}')
    end

    it "returns nil content for a refusal or an answer without choices, for Squishling to reject" do
      stub_post.to_return(reply(completion(nil, refusal: "no")), reply({ choices: [] }))

      expect(adapter.complete(adapter_request).content).to be_nil
      expect(adapter.complete(adapter_request).content).to be_nil
    end

    it "doesn't send OPENAI_API_KEY to another host, only a key given for it" do
      other = stub_request(:post, "https://gateway.example/v1/chat/completions").to_return(reply)

      with_env("OPENAI_API_KEY" => "sk-openai-secret") do
        described_class.new(base_url: "https://gateway.example/v1", max_retries: 0).complete(adapter_request)
      end

      expect(other.with { |req| !req.headers.key?("Authorization") }).to have_been_requested
    end

    it "doesn't send OPENAI_API_KEY over plain http, even to api.openai.com, and matches the host case-insensitively" do
      plain = stub_request(:post, "http://api.openai.com/v1/chat/completions").to_return(reply)
      upper = stub_request(:post, "https://api.openai.com/v1/chat/completions").to_return(reply)

      with_env("OPENAI_API_KEY" => "sk-openai-secret") do
        described_class.new(base_url: "http://api.openai.com/v1", max_retries: 0).complete(adapter_request)
        described_class.new(base_url: "https://API.OPENAI.COM/v1", max_retries: 0).complete(adapter_request)
      end

      expect(plain.with { |req| !req.headers.key?("Authorization") }).to have_been_requested
      expect(upper.with { |req| req.headers["Authorization"] == "Bearer sk-openai-secret" }).to have_been_requested
    end

    it "lets an exception from the api_key callable propagate as it is, without a request or a retry" do
      key = -> { raise Net::ReadTimeout, "vault slow" }

      expect { described_class.new(api_key: key, max_retries: 2).complete(adapter_request) }
        .to raise_error(Net::ReadTimeout)
      expect(WebMock).not_to have_requested(:post, url)
    end

    it "calls the api_key callable once per completion, not per retry" do
      calls = 0
      key = -> { "key-#{calls += 1}" }
      retrying = described_class.new(api_key: key, max_retries: 2)
      allow(retrying).to receive(:sleep)
      stub_post.to_return(reply({}, status: 503), reply)

      retrying.complete(adapter_request)

      expect(calls).to eq(1)
    end

    it "refuses an api_key or header with a line break, without echoing it" do
      secret = "sk-sec\nret"

      expect { described_class.new(api_key: secret, max_retries: 0).complete(adapter_request) }
        .to raise_error(Squishling::ConfigurationError, /line breaks/) { |e| expect(e.message).not_to include("sk-sec") }
      expect { described_class.new(headers: { "X-Key" => secret }) }
        .to raise_error(Squishling::ConfigurationError, /line breaks/) { |e| expect(e.message).not_to include("sk-sec") }
      expect(WebMock).not_to have_requested(:post, url)
    end

    it "refuses a carriage return or NUL in a header name or value, or in the api_key" do
      ["a\rb", "a\0b"].each do |bad|
        [{ headers: { "X-Key" => bad } }, { headers: { bad => "v" } }, { api_key: bad }].each do |options|
          expect { described_class.new(**options).complete(adapter_request) }
            .to raise_error(Squishling::ConfigurationError, /line breaks/)
        end
      end
      expect(WebMock).not_to have_requested(:post, url)
    end

    it "applies open_timeout and read_timeout to the connection" do
      stub_post.to_return(reply)
      timed = described_class.new(api_key: "sk-test", open_timeout: 3, read_timeout: 7, max_retries: 0)
      connections = []
      allow(Net::HTTP).to(receive(:new).and_wrap_original do |original, *args|
        original.call(*args).tap do |http|
          connections << http
        end
      end)

      timed.complete(adapter_request)

      expect(connections.map { |http| [http.open_timeout, http.read_timeout, http.write_timeout] }).to eq([[3, 7, 7]])
    end

    it "strips surrounding whitespace from the api_key" do
      stub = stub_post(headers: { "Authorization" => "Bearer sk-clean" }).to_return(reply)

      described_class.new(api_key: "sk-clean\n", max_retries: 0).complete(adapter_request)

      expect(stub).to have_been_requested
    end

    it "strips any number of trailing slashes from base_url" do
      stub = stub_request(:post, "http://localhost:8000/v1/chat/completions").to_return(reply)

      described_class.new(base_url: "http://localhost:8000/v1//", max_retries: 0).complete(adapter_request)

      expect(stub).to have_been_requested
    end

    it "sends no Authorization header without a key" do
      stub = stub_post.to_return(reply)

      with_env("OPENAI_API_KEY" => nil) { described_class.new(max_retries: 0).complete(adapter_request) }

      expect(stub.with { |req| !req.headers.key?("Authorization") }).to have_been_requested
    end

    it "reads the key from OPENAI_API_KEY when a request is made, or from a callable" do
      stub_post(headers: { "Authorization" => "Bearer from-env" }).to_return(reply)
      stub_post(headers: { "Authorization" => "Bearer from-proc" }).to_return(reply)

      with_env("OPENAI_API_KEY" => "from-env") { described_class.new(max_retries: 0).complete(adapter_request) }
      described_class.new(api_key: -> { "from-proc" }, max_retries: 0).complete(adapter_request)

      expect(WebMock).to have_requested(:post, url).twice
    end

    it "sends extra headers and posts to a custom base_url" do
      stub = stub_request(:post, "http://localhost:11434/v1/chat/completions")
        .with(headers: { "X-Org" => "acme" }).to_return(reply)

      described_class.new(base_url: "http://localhost:11434/v1/", headers: { "X-Org" => "acme" }, max_retries: 0)
        .complete(adapter_request)

      expect(stub).to have_been_requested
    end

    it "uses default_model for a request that names no model, and refuses without one" do
      stub_post.to_return(reply)

      described_class.new(default_model: "llama3", max_retries: 0).complete(adapter_request(model: nil))
      expect(sent_body["model"]).to eq("llama3")

      expect { adapter.complete(adapter_request(model: nil)) }
        .to raise_error(Squishling::ConfigurationError, /Klass#call: no model/)
    end

    it "reaches an IPv6 literal host" do
      stub = stub_request(:post, "http://[::1]:11434/v1/chat/completions").to_return(reply)

      described_class.new(base_url: "http://[::1]:11434/v1", max_retries: 0).complete(adapter_request)

      expect(stub).to have_been_requested
    end

    it "keeps a usage sub-object of any shape from raising" do
      usage = { prompt_tokens: 3, completion_tokens: 1, prompt_tokens_details: "n/a", completion_tokens_details: [1] }
      stub_post.to_return(reply(completion(usage:)))

      expect(adapter.complete(adapter_request).tokens).to eq(input_tokens: 3, output_tokens: 1)
    end

    it "ignores the step's provider" do
      stub_post.to_return(reply)

      adapter.complete(adapter_request(provider: :anthropic))

      expect(sent_body).not_to have_key("provider")
    end
  end

  describe "params" do
    before { stub_post.to_return(reply) }

    it "maps temperature and max_output_tokens, and passes other params through" do
      adapter.complete(adapter_request(params: { temperature: 0.2, max_output_tokens: 300, top_p: 0.9, seed: 7 }))

      expect(sent_body).to include("temperature" => 0.2, "max_completion_tokens" => 300, "top_p" => 0.9, "seed" => 7)
    end

    it "uses max_tokens when asked to" do
      described_class.new(max_tokens_param: :max_tokens).complete(adapter_request(params: { max_output_tokens: 300 }))

      expect(sent_body).to include("max_tokens" => 300)
      expect(sent_body).not_to have_key("max_completion_tokens")
    end

    it "maps thinking effort to reasoning_effort, and leaves true and false to the model's default" do
      adapter.complete(adapter_request(params: { thinking: { effort: :low } }))
      expect(sent_body["reasoning_effort"]).to eq("low")

      [true, false].each do |thinking|
        adapter.complete(adapter_request(params: { thinking: }))
        expect(sent_body).not_to have_key("reasoning_effort")
      end
    end

    it "refuses a thinking budget or display, which Chat Completions has no field for" do
      expect { adapter.complete(adapter_request(params: { thinking: { budget: 1024 } })) }
        .to raise_error(Squishling::ConfigurationError, /thinking budget isn't supported/)
    end

    it "never lets a param replace what Squishling owns" do
      adapter.complete(adapter_request(params: { "model" => "other", n: 3, stream: true, messages: [],
                                                 response_format: {} }))

      expect(sent_body).to include("model" => "gpt-test", "n" => 1, "stream" => false)
      expect(sent_body["messages"].size).to eq(2)
      expect(sent_body.dig("response_format", "type")).to eq("json_schema")
    end
  end

  describe "structured_output:" do
    before { stub_post.to_return(reply) }

    it ":json_object asks for a JSON object and puts the schema in the system prompt" do
      described_class.new(structured_output: :json_object).complete(adapter_request)

      expect(sent_body["response_format"]).to eq("type" => "json_object")
      expect(sent_body["messages"].first["content"]).to include("Classify.", "JSON Schema", '"label"')
    end

    it ":none sends no response_format, only the schema in words" do
      described_class.new(structured_output: "none").complete(adapter_request)

      expect(sent_body).not_to have_key("response_format")
      expect(sent_body["messages"].first["content"]).to include("JSON Schema")
    end
  end

  describe "failures" do
    let(:leaked) { "Incorrect API key provided: sk-test-secret; input was: patient Jane Doe" }

    def error_body(**extra)
      JSON.generate(error: { message: leaked, type: "invalid_request_error", **extra })
    end

    {
      401 => Squishling::ConfigurationError,
      403 => Squishling::ConfigurationError,
      404 => Squishling::ConfigurationError,
      400 => Squishling::ConfigurationError,
      422 => Squishling::ConfigurationError,
      301 => Squishling::ConfigurationError,
      413 => Squishling::LLMError,
      408 => Squishling::LLMError,
      429 => Squishling::LLMError,
      500 => Squishling::LLMError,
      503 => Squishling::LLMError,
      529 => Squishling::LLMError
    }.each do |status, error_class|
      it "maps HTTP #{status} to #{error_class.name.split('::').last}, without the provider's message" do
        stub_post.to_return(reply(error_body, status:))

        expect { adapter.complete(adapter_request) }.to raise_error(error_class, /\AKlass#call: .*#{status}/) do |e|
          expect(e.message).not_to include("sk-test", "Jane Doe", "Incorrect")
        end
      end
    end

    ["This model's maximum context length is 8192 tokens", "prompt is too long: 9000 tokens",
     "Input exceeds the context window of this model", "too many tokens in request"].each do |message|
      it "recognizes an overlong prompt by the wording #{message[0, 30].inspect} when the server sends no code" do
        stub_post.to_return(reply(JSON.generate(error: { message:, type: "BadRequestError" }), status: 400))

        expect { adapter.complete(adapter_request) }.to raise_error(Squishling::LLMError, /HTTP 400/) do |e|
          expect(e.message).not_to include(message)
        end
      end
    end

    it "treats a 400 with an unrelated message, or a body that isn't JSON, as a rejected request" do
      stub_post.to_return(reply(JSON.generate(error: { message: "Unsupported temperature" }), status: 400),
        reply("<html>bad request</html>", status: 400))

      2.times do
        expect { adapter.complete(adapter_request) }.to raise_error(Squishling::ConfigurationError, /HTTP 400/)
      end
    end

    it "treats a 400 whose body is JSON but not an object as a rejected request" do
      stub_post.to_return(reply("null", status: 400), reply("true", status: 400), reply("5", status: 400))

      3.times do
        expect { adapter.complete(adapter_request) }.to raise_error(Squishling::ConfigurationError, /HTTP 400/)
      end
    end

    it "maps a success status with no body (204) to LLMError" do
      stub_post.to_return(status: 204)

      expect do
        adapter.complete(adapter_request)
      end.to raise_error(Squishling::LLMError, /wasn't valid JSON \(HTTP 204\)/)
    end

    it "keeps an overlong-context 400 as an LLMError, since it depends on the input" do
      stub_post.to_return(reply(error_body(code: "context_length_exceeded"), status: 400))

      expect { adapter.complete(adapter_request) }.to raise_error(Squishling::LLMError, /HTTP 400/)
    end

    it "points a rejected request at the one param the server named" do
      stub_post.to_return(reply(error_body(param: "temperature"), status: 400))

      expect { adapter.complete(adapter_request(params: { temperature: 0.1, top_p: 0.5 })) }
        .to raise_error(Squishling::RequestRejectedError,
          /rejected the request \(HTTP 400, invalid_request_error\).*:temperature/) do |e|
          expect(e.message).not_to include("top_p", "Jane Doe")
          expect(e.provider_status).to eq("invalid_request_error")
        end
    end

    it "keeps an overlong-context 400 as an LLMError when the server wraps the error in an Array" do
      stub_post.to_return(reply(JSON.generate([{ error: { code: "context_length_exceeded" } }]), status: 400))

      expect { adapter.complete(adapter_request) }.to raise_error(Squishling::LLMError, /HTTP 400/)
    end

    it "treats a 400 whose body isn't valid UTF-8 as a rejected request" do
      stub_post.to_return(reply("\xFF\xFE bad".b, status: 400))

      expect { adapter.complete(adapter_request) }.to raise_error(Squishling::RequestRejectedError, /HTTP 400/)
    end

    it "words the hint neutrally when the server named no configured param, and exposes the code" do
      stub_post.to_return(reply(error_body(code: "unsupported_value", param: "messages[0].content"), status: 400))

      expect { adapter.complete(adapter_request(params: { temperature: 0.1 })) }
        .to raise_error(Squishling::RequestRejectedError) do |e|
          expect(e.message).to include("HTTP 400, invalid_request_error, unsupported_value", "may be invalid")
          expect(e.message).not_to include("temperature", "messages[0]")
          expect([e.provider_status, e.provider_code]).to eq(%w[invalid_request_error unsupported_value])
        end
    end

    it "has no status or code for a 400 whose body isn't an error object" do
      stub_post.to_return(reply("<html>bad request</html>", status: 400))

      expect { adapter.complete(adapter_request) }.to raise_error(Squishling::RequestRejectedError) do |e|
        expect([e.provider_status, e.provider_code]).to eq([nil, nil])
      end
    end

    it "does not follow redirects, so the key goes nowhere else" do
      stub_post.to_return(status: 302, headers: { "Location" => "https://evil.example/v1/chat/completions" })

      expect { adapter.complete(adapter_request) }
        .to raise_error(Squishling::ConfigurationError, /redirects aren't followed/)
      expect(WebMock).not_to have_requested(:post, "https://evil.example/v1/chat/completions")
    end

    [Net::ReadTimeout, Net::OpenTimeout, Errno::ECONNREFUSED, SocketError, OpenSSL::SSL::SSLError,
     EOFError].each do |type|
      it "maps #{type} to LLMError, keeping it as the cause" do
        stub_post.to_raise(type)

        expect { adapter.complete(adapter_request) }
          .to raise_error(Squishling::LLMError, /the request failed \(#{type}\)/) { |e| expect(e.cause).to be_a(type) }
      end
    end

    it "maps a garbled HTTP response (Net::HTTPBadResponse) to LLMError, without its text" do
      stub_post.to_raise(Net::HTTPBadResponse.new("wrong status line: \"secret input\""))

      expect { adapter.complete(adapter_request) }.to raise_error(Squishling::LLMError, /Net::HTTPBadResponse/) do |e|
        expect(e.message).not_to include("secret input")
      end
    end

    it "treats a certificate that doesn't verify as a setup mistake, not a retryable failure" do
      error = OpenSSL::SSL::SSLError.new("SSL_connect returned=1 errno=0 state=error: certificate verify failed")
      stub_post.to_raise(error)
      retrying = described_class.new(api_key: "sk-test", max_retries: 2)

      expect { retrying.complete(adapter_request) }
        .to raise_error(Squishling::ConfigurationError, /TLS certificate verification failed \(OpenSSL::SSL::SSLError\)/)
      expect(WebMock).to have_requested(:post, url).once
    end

    it "maps a decompression failure to LLMError" do
      stub_post.to_raise(Zlib::DataError)

      expect { adapter.complete(adapter_request) }.to raise_error(Squishling::LLMError, /Zlib::DataError/)
    end

    it "maps a body that isn't JSON, or isn't an object, to LLMError" do
      stub_post.to_return(reply("<html>bad gateway</html>"), reply("[1]"))

      expect { adapter.complete(adapter_request) }.to raise_error(Squishling::LLMError, /wasn't valid JSON/)
      expect { adapter.complete(adapter_request) }.to raise_error(Squishling::LLMError, /wasn't a JSON object/)
    end

    it "keeps a TLS error's own text out of the ConfigurationError, whatever it names" do
      stub_post.to_raise(OpenSSL::SSL::SSLError.new("certificate verify failed: CN=patient-host.internal sk-test"))

      expect { adapter.complete(adapter_request) }.to raise_error(Squishling::ConfigurationError) do |e|
        expect(e.message).to eq("Klass#call: TLS certificate verification failed (OpenSSL::SSL::SSLError); " \
                                "check base_url and the CA certificates")
      end
    end

    it "keeps the body out of the LLMError for a response that isn't JSON or isn't an object" do
      stub_post.to_return(reply("<html>sk-test Jane Doe</html>"), reply('["Jane Doe"]'))

      expect { adapter.complete(adapter_request) }
        .to raise_error(Squishling::LLMError, "Klass#call: the response wasn't valid JSON (HTTP 200)")
      expect { adapter.complete(adapter_request) }
        .to raise_error(Squishling::LLMError, "Klass#call: the response wasn't a JSON object (HTTP 200)")
    end

    it "points 401 and 403 at the credentials and 404 at the model, and only a 400 is a RequestRejectedError" do
      stub_post.to_return(reply("{}", status: 401), reply("{}", status: 403), reply("{}", status: 404),
        reply("{}", status: 400))

      [/refused the credentials/, /refused the credentials/, /check the model name and the endpoint/].each do |text|
        expect { adapter.complete(adapter_request) }.to raise_error(Squishling::ConfigurationError, text) do |e|
          expect(e).not_to be_a(Squishling::RequestRejectedError)
        end
      end
      expect { adapter.complete(adapter_request) }.to raise_error(Squishling::RequestRejectedError)
    end

    it "recognizes a context-length 400 by its type alone, but not a 422 with the same body" do
      body = JSON.generate(error: { type: "context_length_exceeded", message: "too long" })
      stub_post.to_return(reply(body, status: 400), reply(body, status: 422))

      expect { adapter.complete(adapter_request) }.to raise_error(Squishling::LLMError)
      expect { adapter.complete(adapter_request) }.to raise_error(Squishling::ConfigurationError)
    end

    it "falls back to backoff for a Retry-After that isn't a number of seconds" do
      stub_post.to_return(reply({ error: { message: "slow down" } }, status: 429,
        headers: { "Retry-After" => "Thu, 1 Jan 2026 00:00:00 GMT" }), reply)
      retrying = described_class.new(api_key: "sk-test", max_retries: 1)
      delays = []
      allow(retrying).to receive(:sleep) { |seconds| delays << seconds }

      retrying.complete(adapter_request)

      expect(delays.size).to eq(1)
      expect(delays.first).to be_between(0.5, 0.75)
    end

    it "never puts the API key in an error" do
      stub_post.to_return(reply(error_body, status: 500))

      expect { adapter.complete(adapter_request) }.to raise_error(Squishling::LLMError) { |e| expect(e.message).not_to include("sk-test") }
    end
  end

  describe "retries" do
    let(:options) { { api_key: "sk-test", max_retries: 2 } }

    before { allow(adapter).to receive(:sleep) }

    it "retries a 429 or 5xx, then returns the answer" do
      stub_post.to_return(reply({}, status: 429), reply({}, status: 503), reply)

      expect(adapter.complete(adapter_request).content).to eq('{"label":"ok"}')
      expect(WebMock).to have_requested(:post, url).times(3)
    end

    it "retries a network failure" do
      stub_post.to_raise(Net::ReadTimeout).then.to_return(reply)

      expect(adapter.complete(adapter_request).content).to eq('{"label":"ok"}')
    end

    it "gives up after max_retries, raising the last failure" do
      stub_post.to_return(reply({}, status: 503))

      expect { adapter.complete(adapter_request) }.to raise_error(Squishling::LLMError, /HTTP 503/)
      expect(WebMock).to have_requested(:post, url).times(3)
    end

    it "honors Retry-After, capped" do
      stub_post.to_return(reply({}, status: 429, headers: { "Retry-After" => "7" }),
        reply({}, status: 429, headers: { "Retry-After" => "9999" }), reply)

      adapter.complete(adapter_request)

      expect(adapter).to have_received(:sleep).with(7).ordered
      expect(adapter).to have_received(:sleep).with(30).ordered
    end

    it "backs off exponentially without a Retry-After" do
      stub_post.to_return(reply({}, status: 500), reply({}, status: 500), reply)

      adapter.complete(adapter_request)

      expect(adapter).to have_received(:sleep).with(be_between(0.5, 0.75)).ordered
      expect(adapter).to have_received(:sleep).with(be_between(1.0, 1.25)).ordered
    end

    it "does not retry a request the server rejected" do
      stub_post.to_return(reply({}, status: 400))

      expect { adapter.complete(adapter_request) }.to raise_error(Squishling::ConfigurationError)
      expect(WebMock).to have_requested(:post, url).once
    end
  end

  describe "options" do
    {
      { base_url: "ftp://x" } => /base_url must be an http\(s\) URL/,
      { base_url: "not a url" } => /base_url/,
      { base_url: "https://user:pw@host/v1" } => /without credentials/,
      { base_url: "https://host/deployments/d?api-version=1" } => /query/,
      { base_url: "https://host/v1#frag" } => /fragment/,
      { headers: { a: 1 } } => /headers must be a Hash of String/,
      { default_model: "" } => /default_model/,
      { open_timeout: 0 } => /open_timeout must be a positive number/,
      { read_timeout: "x" } => /read_timeout/,
      { max_retries: -1 } => /max_retries/,
      { max_tokens_param: :tokens } => /max_tokens_param must be one of/,
      { structured_output: :xml } => /structured_output must be one of/
    }.each do |bad, message|
      it "rejects #{bad.inspect} before any request" do
        expect { described_class.new(**bad) }.to raise_error(Squishling::ConfigurationError, message)
      end
    end

    it "keeps its own copy of headers, so changing the Hash afterwards can't skip the line-break check" do
      headers = { "X-Key" => +"ok" }
      adapter = described_class.new(headers:, max_retries: 0)
      headers["X-Key"] << "\nsecret"
      headers["X-Other"] = "later"
      stub_post.to_return(reply)

      adapter.complete(adapter_request)

      expect(WebMock).to(have_requested(:post, url).with do |req|
        req.headers["X-Key"] == "ok" && !req.headers.key?("X-Other")
      end)
    end

    it "never puts a secret from base_url in the error" do
      ["https://user:sk-live-key@host/v1", "https://host/v1?key=SECRET", "https://host/v1#SECRET", "http://[bad SECRET"]
        .each do |url|
          expect { described_class.new(base_url: url) }
            .to raise_error(Squishling::ConfigurationError) { |e| expect(e.message).not_to match(/sk-live|SECRET/) }
        end
    end
  end

  describe "end to end" do
    let(:klass) do
      Class.new do
        include Squishling

        squishling model: "gpt-test"
        purpose "Classify."
        output_schema { string :label }
      end
    end

    before { Squishling.configure { |c| c.adapter = { type: :openai_compatible, api_key: "sk-test", max_retries: 0 } } }

    it "answers a squished call with a typed, validated result" do
      stub_post.to_return(reply)

      result = klass.call(text: "x")

      expect(result.label).to eq("ok")
      expect(result).to be_squished
    end

    it "retries invalid output in the same conversation, telling the model what was wrong" do
      klass.squishling(escalation: [{ model: "gpt-test", attempts: 2 }])
      stub_post.to_return(reply(completion('{"label":1}')), reply)

      expect(klass.call(text: "x").label).to eq("ok")
      expect(sent_body["messages"].map { |m| m["role"] }).to eq(%w[system user assistant user])
    end

    it "raises LLMError after the escalation runs out, and ConfigurationError for a bad key without trying again" do
      klass.squishling(escalation: %w[gpt-test other-model])
      stub_post.to_return(reply({}, status: 401))

      expect { klass.call(text: "x") }.to raise_error(Squishling::ConfigurationError, /refused the credentials/)
      expect(WebMock).to have_requested(:post, url).once
    end

    it "retries invalid UTF-8 output in the same conversation instead of failing to send it back" do
      klass.squishling(escalation: [{ model: "gpt-test", attempts: 2 }])
      body = JSON.generate(model: "m", choices: [{ message: { content: '{"label":"xPLACEHOLDER"}' } }]).b
      broken = body.sub("PLACEHOLDER".b, "\xFF".b)
      stub_post.to_return({ status: 200, body: broken }, reply)

      expect(klass.call(text: "x").label).to eq("ok")
      expect(sent_body["messages"].map { |m| m["role"] }).to eq(%w[system user assistant user])
    end

    it "replays an empty answer as a placeholder, since some servers reject an empty assistant message" do
      klass.squishling(escalation: [{ model: "gpt-test", attempts: 2 }])
      stub_post.to_return(reply(completion(nil)), reply)

      expect(klass.call(text: "x").label).to eq("ok")
      expect(sent_body["messages"].map { |m| m["role"] }).to eq(%w[system user assistant user])
      expect(sent_body["messages"][2]["content"]).to eq(Squishling::Adapter::EMPTY_REPLY)
    end

    it "keeps the provider's text out of the fallback's log line" do
      logger = instance_double(Logger, debug: nil, warn: nil)
      Squishling.configure { |c| c.logger = logger }
      klass.squish_fallback { |_error, **| { label: "fallback" } }
      leaked = "Incorrect API key provided: sk-test-secret; input was: patient Jane Doe"
      stub_post.to_return(reply(JSON.generate(error: { message: leaked }), status: 503))

      expect(klass.call(text: "x").label).to eq("fallback")
      expect(logger).to have_received(:warn).with(/LLM failed, using fallback: .*HTTP 503/)
      expect(logger).not_to have_received(:warn).with(/sk-test|Jane Doe/)
    end

    it "carries a call to samples on worker threads" do
      klass.squishling(harness: :squishsum, escalation: %w[a b])
      stub_post.to_return(reply)

      expect(klass.call(text: "x").label).to eq("ok")
      expect(WebMock).to have_requested(:post, url).twice
    end
  end

  def with_env(values)
    saved = values.to_h { |key, _| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| ENV[key] = value }
  end
end
