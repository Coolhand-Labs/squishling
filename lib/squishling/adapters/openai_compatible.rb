# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"
require "zlib"

module Squishling
  module Adapters
    # Sends requests to any server that speaks OpenAI's Chat Completions API (POST {base_url}/chat/completions):
    # OpenAI itself, Ollama, vLLM, LM Studio, llama.cpp, Together, Groq, and the like. Plain Net::HTTP, so it needs
    # no gem beyond Squishling's own. Squishling asks for strict structured output (response_format: json_schema);
    # servers that lack it can use structured_output: :json_object or :none, where the schema goes into the system
    # prompt instead, and Squishling's own validation still decides what is accepted. See docs/adapters.md.
    #
    #   Squishling.configure do |config|
    #     config.adapter = { type: :openai_compatible, base_url: "http://localhost:11434/v1", default_model: "llama3.2" }
    #   end
    class OpenAICompatible < Adapter::Base
      Options = OpenAIOptions
      Transport = OpenAITransport
      private_constant :Options, :Transport

      DEFAULT_BASE_URL = "https://api.openai.com/v1"
      STRUCTURED_OUTPUT = %i[json_schema json_object none].freeze
      TOKEN_PARAMS = %i[max_completion_tokens max_tokens].freeze
      # Params Squishling maps itself; the rest go into the request body as given.
      PORTABLE_PARAMS = %i[temperature thinking max_output_tokens].freeze
      # Failures worth another try inside the adapter: timeouts, connection and protocol trouble (below), HTTP 408,
      # 429, and 5xx. A timeout is retried even though the server may have processed the request.
      NETWORK_ERRORS = [Timeout::Error, SocketError, EOFError, IOError, SystemCallError, Net::ProtocolError,
                        Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, OpenSSL::OpenSSLError, Zlib::Error].freeze
      DEFAULT_MAX_RESPONSE_BYTES = 8 * 1024 * 1024
      MAX_RETRY_DELAY = 30
      # How servers without OpenAI's error code (vLLM, Ollama, llama.cpp, ...) say a prompt is too long. Deliberately
      # narrow (no bare "maximum ... tokens", which a bad max_tokens value also says): a wording that isn't here is a
      # rejected request, which is the safe side. The message is only matched against this, never repeated.
      CONTEXT_LENGTH_MESSAGE = /context (length|window|size)|too many tokens|prompt is too long/i
      private_constant :STRUCTURED_OUTPUT, :TOKEN_PARAMS, :PORTABLE_PARAMS, :NETWORK_ERRORS, :MAX_RETRY_DELAY,
        :CONTEXT_LENGTH_MESSAGE

      # base_url: the API root, ending where /chat/completions starts. api_key: a String, or a callable that returns
      # one; for OpenAI's own endpoint it defaults to ENV["OPENAI_API_KEY"] (read when a request is made). Any other
      # endpoint gets only the key you give it, so an OpenAI key can't reach another host. None is sent when the key
      # is blank (local servers). headers: extra request headers. default_model: used for steps that name no model.
      # max_retries: how often a timeout, connection failure, HTTP 408, 429, or 5xx is retried here (honoring
      # Retry-After) before it surfaces as an LLMError. max_tokens_param: the body key for max_output_tokens
      # (:max_completion_tokens, or :max_tokens for older servers). structured_output: :json_schema, :json_object,
      # or :none. allow_insecure_http: lets a credential (api_key, or a header such as Authorization or api-key) go
      # over plain http to a host that isn't loopback; without it that is a ConfigurationError. max_response_bytes:
      # the most a response (an error body too) may hold, 8 MiB by default. total_timeout: the most seconds one
      # attempt may take (read_timeout restarts at every read); it defaults to open_timeout + 2 * read_timeout.
      # Responses are requested and accepted uncompressed only. Raises ConfigurationError for a bad option.
      def initialize(base_url: DEFAULT_BASE_URL, api_key: nil, headers: {}, default_model: nil, open_timeout: 10,
        read_timeout: 120, max_retries: 2, max_tokens_param: :max_completion_tokens, structured_output: :json_schema,
        allow_insecure_http: false, max_response_bytes: DEFAULT_MAX_RESPONSE_BYTES, total_timeout: nil)
        super()
        @endpoint = Options.endpoint(base_url)
        @api_key = (Secret.new(api_key) unless api_key.nil?)
        @headers = Secret.new(Options.headers(headers))
        @allow_insecure_http = Options.flag(:allow_insecure_http, allow_insecure_http)
        @default_model = Options.default_model(default_model)
        @max_retries = Options.retries(max_retries)
        @max_tokens_param = Options.choice(:max_tokens_param, max_tokens_param, TOKEN_PARAMS)
        @structured_output = Options.choice(:structured_output, structured_output, STRUCTURED_OUTPUT)
        @transport = build_transport(open_timeout, read_timeout, total_timeout, max_response_bytes)
        check_cleartext!(api_key.respond_to?(:call) ? nil : api_key)
      end

      # Shows where requests go, never the key or the header values (a console, a log line, or an error tracker may
      # print the config). The key and headers are held in a Secret, so to_yaml, as_json and Marshal can't expose them
      # either.
      def inspect
        "#<#{self.class.name} #{@endpoint.scheme}://#{@endpoint.authority}#{@endpoint.path} " \
          "default_model=#{@default_model.inspect} structured_output=#{@structured_output.inspect}>"
      end

      def complete(request)
        model = request.model || @default_model
        unless model
          raise configuration_error(request,
            "no model: name one with model: or give the adapter a default_model:")
        end

        data = post(request, JSON.generate(body(request, model)), request_headers(request))
        Adapter::Response.new(content: content_of(data), model: data["model"] || model,
          tokens: tokens_of(data["usage"]), finish_reason: finish_reason_of(data))
      end

      private

      # Params first, then what Squishling owns, so a param can never replace the model, the conversation, or the
      # strict output format. n and stream are fixed: one non-streamed completion.
      def body(request, model)
        params = request.params
        body = params.except(*PORTABLE_PARAMS).transform_keys(&:to_s)
        body["temperature"] = params[:temperature] if params.key?(:temperature)
        body[@max_tokens_param.to_s] = params[:max_output_tokens] if params.key?(:max_output_tokens)
        body.merge!(reasoning(request, params[:thinking]))
        body.merge("model" => model, "messages" => messages(request), "n" => 1, "stream" => false)
          .merge(response_format(request))
      end

      # Chat Completions only has reasoning_effort: true and false have no equivalent, so they leave the default.
      def reasoning(request, thinking)
        return {} unless thinking.is_a?(Hash)

        unsupported = thinking.keys - [:effort]
        unless unsupported.empty?
          raise configuration_error(request, "thinking #{unsupported.join(', ')} isn't supported by this adapter " \
                                             "(only thinking: { effort: })")
        end

        { "reasoning_effort" => thinking[:effort].to_s }
      end

      def messages(request)
        system = system_prompt(request)
        turns = request.messages.map { |message| { "role" => message[:role].to_s, "content" => message[:content] } }
        system ? [{ "role" => "system", "content" => system }] + turns : turns
      end

      # Without response_format: json_schema the model has to be told the schema in words.
      def system_prompt(request)
        return request.instructions if @structured_output == :json_schema

        schema = JSON.pretty_generate(request.schema["schema"])
        [request.instructions,
         "Respond only with JSON that validates against this JSON Schema:\n#{schema}"].compact.join("\n\n")
      end

      def response_format(request)
        case @structured_output
        when :json_schema then { "response_format" => { "type" => "json_schema",
                                                        "json_schema" => json_schema(request) } }
        when :json_object then { "response_format" => { "type" => "json_object" } }
        else {}
        end
      end

      def json_schema(request)
        schema = request.schema
        name = schema["name"].to_s.gsub(/[^A-Za-z0-9_-]/, "_")[0, 64]
        { "name" => name.empty? ? "response" : name, "description" => schema["description"],
          "schema" => schema["schema"], "strict" => true }.compact
      end

      # One request, retried here for failures worth retrying. A refusal or an empty answer is returned as empty
      # content, which Squishling reports as invalid output.
      def post(request, body, headers)
        attempt = 0
        loop do
          attempt += 1
          response, error = exchange(body, headers)
          return parse_body(request, response) if response&.success?

          failure = failure_for(request, response, error)
          raise failure, cause: error unless retryable?(response, error) && attempt <= @max_retries

          pause(retry_delay(response, attempt))
        end
      rescue Transport::Refused => e
        # A size or time limit, or compression: the same request would hit it again, so it isn't retried.
        raise llm_error(request, e.message), cause: e
      end

      def exchange(body, headers)
        [@transport.post(body, headers), nil]
      rescue *NETWORK_ERRORS => e
        [nil, e]
      end

      def build_transport(open_timeout, read_timeout, total_timeout, max_response_bytes)
        open_timeout = Options.number(:open_timeout, open_timeout)
        read_timeout = Options.number(:read_timeout, read_timeout)
        Transport.new(endpoint: @endpoint, open_timeout:, read_timeout:,
          total_timeout: Options.total_timeout(total_timeout, open_timeout, read_timeout),
          max_response_bytes: Options.number(:max_response_bytes, max_response_bytes, type: Integer))
      end

      # Built once per call, before any request and outside the network-error rescue, so the developer's own api_key
      # callable runs once and its exceptions propagate as they are.
      def request_headers(request)
        key = api_key_value.to_s.strip
        if Options.unsafe_header?(key)
          raise configuration_error(request,
            "the api_key can't contain line breaks or NUL")
        end
        check_cleartext!(key, request)

        headers = { "Content-Type" => "application/json", "Accept" => "application/json",
                    "User-Agent" => "squishling/#{VERSION}" }
        headers["Authorization"] = "Bearer #{key}" unless key.empty?
        # Accept-Encoding is Squishling's own: a compressed response would be inflated past the size cap.
        headers.merge(@headers.reveal).reject { |name, _| name.casecmp?("accept-encoding") }
          .merge("Accept-Encoding" => "identity")
      end

      def api_key_value
        key = @api_key&.reveal
        key.respond_to?(:call) ? key.call : (key || default_api_key)
      end

      # A credential doesn't go over plain http to another machine unless allow_insecure_http: says so. Checked when the
      # adapter is built for a key given as a String, and again with each request's own key (a callable's). Reads the
      # headers through their Secret; the message names neither the key nor a header value.
      def check_cleartext!(key, request = nil)
        return if @allow_insecure_http || !Options.cleartext_credential?(@endpoint, key, @headers.reveal)

        raise configuration_error(request, Options::CLEARTEXT_CREDENTIAL) if request

        raise ConfigurationError, Options::CLEARTEXT_CREDENTIAL
      end

      def default_api_key
        default = URI.parse(DEFAULT_BASE_URL)
        return unless @endpoint.scheme == default.scheme && @endpoint.hostname.downcase == default.hostname

        ENV.fetch("OPENAI_API_KEY", nil)
      end

      def parse_body(request, response)
        data = JSON.parse(response.body.to_s.dup.force_encoding(Encoding::UTF_8))
        return data if data.is_a?(Hash)

        raise llm_error(request, "the response wasn't a JSON object (HTTP #{response.code})")
      rescue JSON::ParserError
        raise llm_error(request, "the response wasn't valid JSON (HTTP #{response.code})")
      end

      def retryable?(response, error)
        return !certificate_failure?(error) if error

        status = response.code.to_i
        [408, 429].include?(status) || status >= 500
      end

      # The provider's own message is never repeated: only the class of failure or the HTTP status.
      def failure_for(request, response, error)
        return transport_failure(request, error) if error

        status = response.code.to_i
        http_failure(request, status:, body: response.body.to_s, via: "HTTP #{status}")
      end

      # A certificate that doesn't verify is a setup mistake (base_url, CA store) that a retry can't fix.
      def transport_failure(request, error)
        if certificate_failure?(error)
          return configuration_error(request, "TLS certificate verification failed (#{error.class}); check base_url " \
                                              "and the CA certificates")
        end

        llm_error(request, "the request failed (#{error.class})")
      end

      def certificate_failure?(error)
        error.is_a?(OpenSSL::SSL::SSLError) && error.message.include?("certificate verify failed")
      end

      # The structured code or type, as for any adapter, or the usual wording of a server that sends none (a 400).
      def context_length?(status:, body:)
        super || (status == 400 && Adapter::ErrorBody.error(body)&.[]("message").to_s.match?(CONTEXT_LENGTH_MESSAGE))
      end

      def retry_delay(response, attempt)
        after = response&.retry_after.to_s
        seconds = after.match?(/\A\d+\z/) ? after.to_i : (0.5 * (2**(attempt - 1))) + (rand * 0.25)
        [seconds, MAX_RETRY_DELAY].min
      end

      def pause(seconds)
        sleep(seconds)
      end

      def content_of(data)
        message = Array(data["choices"]).first
        message = message["message"] if message.is_a?(Hash)
        content = message.is_a?(Hash) ? message["content"] : nil
        content.is_a?(Array) ? content.filter_map { |part| part["text"] if part.is_a?(Hash) }.join : content
      end

      # The first choice's finish_reason, in the vocabulary of Adapter::Response ("length" is the output cap).
      def finish_reason_of(data)
        choice = Array(data["choices"]).first
        reason = choice["finish_reason"] if choice.is_a?(Hash)
        return unless reason.is_a?(String)

        reason == "length" ? :max_tokens : reason
      end

      def tokens_of(usage)
        return {} unless usage.is_a?(Hash)

        {
          input_tokens: usage["prompt_tokens"],
          output_tokens: usage["completion_tokens"],
          cache_read_tokens: detail(usage, "prompt_tokens_details", "cached_tokens"),
          thinking_tokens: detail(usage, "completion_tokens_details", "reasoning_tokens")
        }.select { |_, count| count.is_a?(Integer) }
      end

      # A count inside a usage sub-object, which a server might send in any shape.
      def detail(usage, group, key)
        usage[group][key] if usage[group].is_a?(Hash)
      end
    end

    Adapter::Registry.register_built_in(:openai_compatible, OpenAICompatible)
  end
end
