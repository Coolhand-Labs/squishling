# frozen_string_literal: true

require "ruby_llm"
require "webmock/rspec"

# Both built-in adapters classify a provider's HTTP failure through Adapter::Base#http_failure, so the same status
# means the same thing whichever adapter made the request.
RSpec.describe "Provider failure classification" do # rubocop:disable RSpec/DescribeClass
  let(:leaked) { "Incorrect API key provided: sk-test-secret; input was: patient Jane Doe" }

  def body_with(**error)
    { "error" => { "message" => leaked, "type" => "invalid_request_error" }.merge(error.transform_keys(&:to_s)) }
  end

  # Each adapter provides #fail_with(status, body), which makes the provider answer the next request that way, and
  # #adapter, whose #complete then raises what the request fails with.
  shared_examples "the HTTP status contract" do
    {
      400 => Squishling::RequestRejectedError,
      401 => Squishling::ConfigurationError,
      402 => Squishling::ConfigurationError,
      403 => Squishling::ConfigurationError,
      404 => Squishling::ConfigurationError,
      409 => Squishling::RequestRejectedError,
      422 => Squishling::RequestRejectedError,
      301 => Squishling::ConfigurationError,
      408 => Squishling::LLMError,
      413 => Squishling::LLMError,
      429 => Squishling::LLMError,
      500 => Squishling::LLMError,
      503 => Squishling::LLMError
    }.each do |status, error_class|
      it "maps HTTP #{status} to #{error_class.name.split('::').last}, without the provider's message" do
        fail_with(status, body_with)

        expect { adapter.complete(adapter_request) }.to raise_error(error_class, /\AKlass#call: .*#{status}/) do |e|
          expect(e.message).not_to include("sk-test", "Jane Doe", "Incorrect")
          expect(e.is_a?(Squishling::RequestRejectedError)).to eq(error_class == Squishling::RequestRejectedError)
        end
      end
    end

    it "reads a 400's wording as a plain rejected request, never as a reason to retry" do
      ["The maximum value for `max_tokens` is 4096", "maximum tokens: none", "Unsupported temperature"]
        .each do |message|
        fail_with(400, body_with(message:))

        expect { adapter.complete(adapter_request) }.to raise_error(Squishling::RequestRejectedError) do |e|
          expect(e.message).not_to include(message)
        end
      end
    end

    it "treats a structured context_length_exceeded code or type on a 400 as an LLMError" do
      [body_with(code: "context_length_exceeded"), body_with(type: "context_length_exceeded"),
       [body_with(code: "context_length_exceeded")]].each do |body|
        fail_with(400, body)

        expect { adapter.complete(adapter_request) }.to raise_error(Squishling::LLMError, /HTTP 400/) do |e|
          expect(e.message).not_to include("Jane Doe")
        end
      end
    end

    it "keeps a structured overflow code on any other 4xx a rejected request" do
      fail_with(422, body_with(code: "context_length_exceeded"))

      expect { adapter.complete(adapter_request) }.to raise_error(Squishling::RequestRejectedError)
    end

    it "carries a rejection's provider status and code, not its message" do
      fail_with(400, body_with(code: "unsupported_value"))

      expect { adapter.complete(adapter_request) }.to raise_error(Squishling::RequestRejectedError) do |e|
        expect([e.provider_status, e.provider_code]).to eq(%w[invalid_request_error unsupported_value])
        expect(e.message).not_to include("Jane Doe")
      end
    end
  end

  describe Squishling::Adapters::OpenAICompatible do
    let(:adapter) { described_class.new(api_key: "sk-test", max_retries: 0) }

    def fail_with(status, body)
      stub_request(:post, "https://api.openai.com/v1/chat/completions")
        .to_return(status:, body: body.is_a?(String) ? body : JSON.generate(body),
          headers: { "Content-Type" => "application/json" })
    end

    it_behaves_like "the HTTP status contract"

    it "also recognizes the usual wording of a server that sends no code, on a 400" do
      ["This model's maximum context length is 8192 tokens", "prompt is too long: 9000 tokens",
       "Input exceeds the context window of this model", "too many tokens in request"].each do |message|
        fail_with(400, body_with(message:))

        expect { adapter.complete(adapter_request) }.to raise_error(Squishling::LLMError, /HTTP 400/) do |e|
          expect(e.message).not_to include(message)
        end
      end
    end

    it "does not read that wording on another 4xx" do
      fail_with(422, body_with(message: "the context window is fine"))

      expect { adapter.complete(adapter_request) }.to raise_error(Squishling::RequestRejectedError)
    end
  end

  describe Squishling::Adapters::RubyLLM do
    let(:adapter) { described_class.new }
    let(:response_class) { Struct.new(:status, :body) }

    # The next request fails with the error (RubyLLM::Error, whose response alone says what happened, by default).
    def fail_with(status, body, type = RubyLLM::Error)
      fail_chat(type.new(leaked, response: response_class.new(status, body)))
    end

    def fail_chat(error)
      chat = Object.new
      %i[with_instructions with_schema].each { |name| chat.define_singleton_method(name) { |*| self } }
      chat.define_singleton_method(:ask) { |*| raise error }
      allow(RubyLLM).to receive(:chat).and_return(chat)
      error
    end

    it_behaves_like "the HTTP status contract"

    it "sorts a 400 by its status, whatever class RubyLLM's message matching picked" do
      [RubyLLM::RateLimitError, RubyLLM::UnauthorizedError, RubyLLM::OverloadedError,
       RubyLLM::PaymentRequiredError].each do |type|
        error = fail_with(400, body_with, type)

        expect { adapter.complete(adapter_request) }
          .to raise_error(Squishling::RequestRejectedError, /#{type.name}, HTTP 400/) { |e| expect(e.cause).to equal(error) }
      end
    end

    it "treats an unusable reply that came with a success status as an LLMError" do
      fail_with(200, "", RubyLLM::ServerError)

      expect { adapter.complete(adapter_request) }.to raise_error(Squishling::LLMError, /ServerError, HTTP 200/)
    end

    it "honors RubyLLM's own context-length error, which knows its provider's wording" do
      error = fail_with(400, body_with, RubyLLM::ContextLengthExceededError)

      expect { adapter.complete(adapter_request) }
        .to raise_error(Squishling::LLMError, /ContextLengthExceededError, HTTP 400/) do |e|
          expect(e.message).not_to include("Jane Doe")
          expect(e.cause).to equal(error)
        end
    end

    {
      RubyLLM::UnauthorizedError => Squishling::ConfigurationError,
      RubyLLM::PaymentRequiredError => Squishling::ConfigurationError,
      RubyLLM::ForbiddenError => Squishling::ConfigurationError,
      RubyLLM::BadRequestError => Squishling::RequestRejectedError,
      RubyLLM::ServerError => Squishling::LLMError,
      RubyLLM::Error => Squishling::LLMError
    }.each do |type, error_class|
      it "sorts #{type.name} raised without a response by its class, to #{error_class.name.split('::').last}" do
        error = fail_chat(type.new("Jane Doe"))

        message = /\AKlass#call: .*#{type.name}\b/
        expect { adapter.complete(adapter_request) }.to raise_error(error_class, message) do |e|
          expect(e.message).not_to include("Jane Doe")
          expect(e.cause).to equal(error)
        end
      end
    end
  end
end
