# frozen_string_literal: true

require "webmock/rspec"

# Transport hardening of the OpenAI-compatible adapter: no credential in the clear to another machine, a cap on the
# response size, no compression, and a bound on the total time of a request.
RSpec.describe Squishling::Adapters::OpenAITransport do # rubocop:disable RSpec/SpecFilePathFormat -- openai, not open_ai
  let(:adapter_class) { Squishling::Adapters::OpenAICompatible }
  let(:url) { "https://api.openai.com/v1/chat/completions" }
  let(:reply_body) do
    JSON.generate(model: "m", choices: [{ message: { content: '{"label":"ok"}' }, finish_reason: "stop" }])
  end

  def stub_post(target = url)
    stub_request(:post, target)
  end

  def complete(**options)
    adapter_class.new(api_key: "sk-test", max_retries: 0, **options).complete(adapter_request)
  end

  describe "credentials over plain http" do
    let(:lan) { "http://gateway.lan:8000/v1" }
    let(:lan_url) { "http://gateway.lan:8000/v1/chat/completions" }

    it "refuses an api_key sent to a host that isn't this machine, without a request or the key or URL in the error" do
      expect { adapter_class.new(base_url: lan, api_key: "sk-secret-key") }
        .to raise_error(Squishling::ConfigurationError, /allow_insecure_http: true/) do |e|
          expect(e.message).not_to include("sk-secret-key", "gateway.lan")
        end
      expect(WebMock).not_to have_requested(:post, lan_url)
    end

    it "refuses an Authorization header in any letter case" do
      expect { adapter_class.new(base_url: lan, headers: { "authorization" => "Bearer abc" }) }
        .to raise_error(Squishling::ConfigurationError, /won't send credentials/)
    end

    it "refuses a key from a callable when the request is made, labelled with the call" do
      stub = stub_post(lan_url).to_return(status: 200, body: reply_body)
      adapter = adapter_class.new(base_url: lan, api_key: -> { "sk-from-vault" })

      expect { adapter.complete(adapter_request) }
        .to raise_error(Squishling::ConfigurationError, /\AKlass#call: .*allow_insecure_http: true/) do |e|
          expect(e.message).not_to include("sk-from-vault", "gateway.lan")
        end
      expect(stub).not_to have_been_requested
    end

    it "lets a callable that returns nothing go out without a credential" do
      stub = stub_post(lan_url).to_return(status: 200, body: reply_body)

      adapter_class.new(base_url: lan, api_key: -> { "" }, max_retries: 0).complete(adapter_request)

      expect(stub).to have_been_requested
    end

    it "sends the credential when allow_insecure_http: true" do
      stub = stub_post(lan_url).with(headers: { "Authorization" => "Bearer sk-test" })
        .to_return(status: 200, body: reply_body)

      complete(base_url: lan, allow_insecure_http: true)

      expect(stub).to have_been_requested
    end

    it "sends no credential, and needs no opt-out, without an api_key or Authorization header" do
      stub = stub_post(lan_url).with(headers: { "X-Org" => "acme" }).to_return(status: 200, body: reply_body)

      adapter_class.new(base_url: lan, headers: { "X-Org" => "acme" }, max_retries: 0).complete(adapter_request)

      expect(stub).to have_been_requested
    end

    [
      "http://localhost:11434/v1", "http://LOCALHOST.:11434/v1", "http://ollama.localhost:11434/v1",
      "http://127.0.0.1:11434/v1", "http://127.9.9.9:11434/v1", "http://[::1]:11434/v1"
    ].each do |base_url|
      it "treats #{base_url} as this machine" do
        stub = stub_post("#{base_url.sub('.:', ':').sub('LOCALHOST', 'localhost')}/chat/completions")
          .to_return(status: 200, body: reply_body)

        expect { complete(base_url:) }.not_to raise_error
        expect(stub).to have_been_requested
      end
    end

    [
      "http://10.0.0.5/v1", "http://192.168.1.2/v1", "http://[fd00::1]/v1", "http://127.0.0.1.evil.example/v1",
      "http://notlocalhost/v1", "http://localhost.example.com/v1", "http://host.docker.internal/v1"
    ].each do |base_url|
      it "treats #{base_url} as another machine" do
        expect { adapter_class.new(base_url:, api_key: "sk-test") }
          .to raise_error(Squishling::ConfigurationError, /plain http/)
      end
    end

    it "never refuses https, with or without the opt-out" do
      stub = stub_post("https://gateway.lan:8000/v1/chat/completions").to_return(status: 200, body: reply_body)

      complete(base_url: "https://gateway.lan:8000/v1")

      expect(stub).to have_been_requested
    end

    it "doesn't resolve a host name to decide" do
      allow(Addrinfo).to receive(:getaddrinfo)
      allow(IPSocket).to receive(:getaddress)

      expect { adapter_class.new(base_url: "http://resolves-to-loopback.test/v1", api_key: "sk-test") }
        .to raise_error(Squishling::ConfigurationError)
      expect(Addrinfo).not_to have_received(:getaddrinfo)
      expect(IPSocket).not_to have_received(:getaddress)
    end
  end

  describe "options" do
    {
      { allow_insecure_http: "yes" } => /allow_insecure_http must be true or false/,
      { allow_insecure_http: nil } => /allow_insecure_http/,
      { max_response_bytes: 0 } => /max_response_bytes must be a positive Integer/,
      { max_response_bytes: 1.5 } => /max_response_bytes/,
      { max_response_bytes: "8" } => /max_response_bytes/,
      { total_timeout: 0 } => /total_timeout must be a positive number/,
      { total_timeout: "x" } => /total_timeout/
    }.each do |bad, message|
      it "rejects #{bad.inspect} before any request" do
        expect { adapter_class.new(**bad) }.to raise_error(Squishling::ConfigurationError, message)
      end
    end
  end

  describe "the request" do
    it "asks for an uncompressed response" do
      stub = stub_post.with(headers: { "Accept-Encoding" => "identity" }).to_return(status: 200, body: reply_body)

      complete

      expect(stub).to have_been_requested
    end

    it "replaces an Accept-Encoding header of the caller's, in any letter case" do
      stub = stub_post.with { |req| req.headers["Accept-Encoding"] == "identity" }
        .to_return(status: 200, body: reply_body)

      complete(headers: { "accept-encoding" => "gzip, deflate" })

      expect(stub).to have_been_requested
    end

    it "refuses a response that is compressed anyway, without a retry or any of it in the error" do
      stub_post.to_return(status: 200, body: "\x1F\x8B secret".b, headers: { "Content-Encoding" => "gzip" })
      retrying = adapter_class.new(api_key: "sk-test", max_retries: 2)
      allow(retrying).to receive(:sleep)

      expect { retrying.complete(adapter_request) }
        .to raise_error(Squishling::LLMError, /\AKlass#call: the response was compressed/) do |e|
          expect(e.message).not_to include("secret", "gzip")
        end
      expect(WebMock).to have_requested(:post, url).once
    end

    it "accepts an explicit identity encoding" do
      stub_post.to_return(status: 200, body: reply_body, headers: { "Content-Encoding" => "identity" })

      expect(complete.content).to eq('{"label":"ok"}')
    end
  end

  describe "the response size cap" do
    it "defaults to 8 MiB" do
      stub_post.to_return(status: 200, body: reply_body, headers: { "Content-Length" => ((8 * 1024 * 1024) + 1).to_s })

      expect { complete }.to raise_error(Squishling::LLMError, /max_response_bytes \(8388608\)/)
    end

    it "accepts a body of exactly the cap and refuses one a byte over" do
      stub_post.to_return({ status: 200, body: reply_body }, { status: 200, body: reply_body })
      size = reply_body.bytesize

      expect(complete(max_response_bytes: size).content).to eq('{"label":"ok"}')
      expect { complete(max_response_bytes: size - 1) }
        .to raise_error(Squishling::LLMError, /\AKlass#call: the response was larger than max_response_bytes/)
    end

    it "counts bytes, not characters" do
      body = JSON.generate(model: "m", choices: [{ message: { content: "é" * 20 } }])
      stub_post.to_return(status: 200, body:)

      expect { complete(max_response_bytes: body.length) }.to raise_error(Squishling::LLMError, /max_response_bytes/)
    end

    it "refuses on a declared Content-Length before reading the body" do
      stub_post.to_return(status: 200, body: "{}", headers: { "Content-Length" => "100000" })

      expect { complete(max_response_bytes: 1000) }.to raise_error(Squishling::LLMError, /max_response_bytes \(1000\)/)
    end

    it "caps an error body too, and puts none of it in the error" do
      stub_post.to_return(status: 400, body: "secret " * 100)

      expect { complete(max_response_bytes: 100) }
        .to raise_error(Squishling::LLMError, /max_response_bytes/) { |e| expect(e.message).not_to include("secret") }
    end

    it "isn't retried, even for a status that would be" do
      stub_post.to_return(status: 503, body: "x" * 500)
      retrying = adapter_class.new(api_key: "sk-test", max_retries: 3, max_response_bytes: 100)
      allow(retrying).to receive(:sleep)

      expect { retrying.complete(adapter_request) }.to raise_error(Squishling::LLMError, /max_response_bytes/)
      expect(WebMock).to have_requested(:post, url).once
      expect(retrying).not_to have_received(:sleep)
    end

    it "keeps the limit as the cause" do
      stub_post.to_return(status: 200, body: "x" * 500)

      expect { complete(max_response_bytes: 100) }.to raise_error(Squishling::LLMError) do |e|
        expect(e.cause).to be_a(described_class::ResponseTooLarge)
      end
    end
  end

  describe "the total time limit" do
    let(:endpoint) { URI.parse(url) }

    def transport(clock:, **options)
      described_class.new(endpoint:, open_timeout: 10, read_timeout: 120, total_timeout: 30,
        max_response_bytes: 1000, clock:, **options)
    end

    def clock_of(*times)
      ticks = times.each
      -> { ticks.next }
    end

    it "defaults to open_timeout plus twice read_timeout" do
      transport = instance_double(described_class, post: described_class::Reply.new("200", reply_body, nil))
      allow(described_class).to receive(:new).and_return(transport)

      adapter_class.new(open_timeout: 3, read_timeout: 7)
      adapter_class.new(open_timeout: 3, read_timeout: 7, total_timeout: 5)

      expect(described_class).to have_received(:new).with(hash_including(total_timeout: 17))
      expect(described_class).to have_received(:new).with(hash_including(total_timeout: 5))
    end

    it "bounds the connection's timeouts by what is left, and returns what it read" do
      stub_post.to_return(status: 200, body: reply_body)
      connections = []
      allow(Net::HTTP).to(receive(:new).and_wrap_original { |m, *args| m.call(*args).tap { |h| connections << h } })

      reply = transport(clock: clock_of(0.0, 25.0, 25.0, 25.0), total_timeout: 30).post("{}", {})

      expect(reply).to be_success
      expect(reply.body).to eq(reply_body)
      # 5 seconds were left for the first read, and the same again once the body was in
      expect(connections.map { |http| [http.open_timeout, http.read_timeout] }).to eq([[10, 5.0]])
    end

    it "stops reading once the deadline has passed, at the first chunk" do
      stub_post.to_return(status: 200, body: reply_body)

      expect { transport(clock: clock_of(0.0, 1.0, 100.0)).post("{}", {}) }
        .to raise_error(described_class::DeadlineExceeded, /total_timeout \(30s\)/)
    end

    it "treats a timeout after the deadline as the deadline, and one before it as a timeout" do
      stub_post.to_timeout

      expect { transport(clock: clock_of(0.0, 1.0, 100.0)).post("{}", {}) }
        .to raise_error(described_class::DeadlineExceeded)
      expect { transport(clock: -> { 0.0 }).post("{}", {}) }.to raise_error(Net::OpenTimeout)
    end

    it "fails the call as an LLMError, once, without the adapter retrying it" do
      stub_post.to_return(status: 200, body: reply_body)
      retrying = adapter_class.new(api_key: "sk-test", max_retries: 2, total_timeout: 30)
      allow(retrying).to receive(:sleep)
      ticks = [0.0, 1.0, 100.0].each
      allow(Process).to receive(:clock_gettime).and_wrap_original do |original, *args|
        args == [Process::CLOCK_MONOTONIC] ? ticks.next : original.call(*args)
      end

      expect { retrying.complete(adapter_request) }
        .to raise_error(Squishling::LLMError, /\AKlass#call: the request ran past total_timeout \(30s\)/)
      expect(WebMock).to have_requested(:post, url).once
    end
  end
end
