# frozen_string_literal: true

require "ipaddr"
require "uri"

module Squishling
  module Adapters
    # Checks the options of Adapters::OpenAICompatible, raising ConfigurationError (without echoing a value that may
    # be a secret) for a bad one.
    module OpenAIOptions
      # The URL itself is never in the message: it may carry credentials.
      INVALID_BASE_URL = "adapter :openai_compatible base_url must be an http(s) URL without credentials (use " \
                         "api_key:), a query, or a fragment"
      # Headers that carry a secret as a matter of course (OpenAI-style, Azure OpenAI, and proxies).
      CREDENTIAL_HEADERS = %w[authorization proxy-authorization api-key x-api-key].freeze
      CLEARTEXT_CREDENTIAL = "adapter :openai_compatible won't send credentials (the api_key or a header such as " \
                             "Authorization or api-key) over plain http to a host that isn't this machine; use " \
                             "https, or pass allow_insecure_http: true to accept the risk on a network you trust"
      INVALID_HEADER = "adapter :openai_compatible headers (and the api_key) can't contain line breaks or NUL"

      module_function

      def endpoint(base_url)
        uri = URI.parse(base_url.to_s.strip.sub(%r{/+\z}, ""))
        unless uri.is_a?(URI::HTTP) && uri.host && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
          raise ConfigurationError, INVALID_BASE_URL
        end

        URI.parse("#{uri}/chat/completions")
      rescue URI::InvalidURIError
        raise ConfigurationError, INVALID_BASE_URL
      end

      def headers(headers)
        unless headers.is_a?(Hash) && headers.all? { |name, value| name.is_a?(String) && value.is_a?(String) }
          raise ConfigurationError, "adapter :openai_compatible headers must be a Hash of String names to String values"
        end
        raise ConfigurationError, INVALID_HEADER if headers.flatten.any? { |text| unsafe_header?(text) }

        # A copy, so the caller can't change a header after the check above.
        headers.to_h { |name, value| [name.dup.freeze, value.dup.freeze] }.freeze
      end

      # Net::HTTP raises, with the value in the message, for a header that carries a line break.
      def unsafe_header?(text)
        text.match?(/[\r\n\0]/)
      end

      # Whether a credential would travel in the clear: over http, to a host that isn't loopback (a name is judged by
      # its spelling, never resolved, so a lookup can't change the answer).
      def cleartext?(endpoint)
        endpoint.scheme == "http" && !loopback?(endpoint.hostname)
      end

      def loopback?(host)
        host = host.downcase.delete_suffix(".")
        host == "localhost" || host.end_with?(".localhost") || IPAddr.new(host).loopback?
      rescue IPAddr::Error
        false
      end

      # Whether a request to endpoint, with this key (a String, possibly blank) and these headers, would send a
      # credential in the clear.
      def cleartext_credential?(endpoint, key, headers)
        return false unless cleartext?(endpoint)

        !key.to_s.strip.empty? || headers.each_key.any? { |name| CREDENTIAL_HEADERS.include?(name.downcase) }
      end

      def flag(name, value)
        return value if [true, false].include?(value)

        raise ConfigurationError, "adapter :openai_compatible #{name} must be true or false, got #{value.inspect}"
      end

      # Defaults to the time the three timeouts allow together: connecting, writing the request, one read.
      def total_timeout(value, open_timeout, read_timeout)
        return open_timeout + (2 * read_timeout) if value.nil?

        number(:total_timeout, value)
      end

      def default_model(model)
        return nil if model.nil?
        return model.to_s if (model.is_a?(String) || model.is_a?(Symbol)) && !model.to_s.strip.empty?

        raise ConfigurationError, "adapter :openai_compatible default_model must be a model name, got #{model.inspect}"
      end

      def number(name, value, type: Numeric)
        return value if value.is_a?(type) && value.positive?

        kind = type == Integer ? "Integer" : "number"
        raise ConfigurationError, "adapter :openai_compatible #{name} must be a positive #{kind}, got #{value.inspect}"
      end

      def retries(value)
        return value if value.is_a?(Integer) && !value.negative?

        raise ConfigurationError,
          "adapter :openai_compatible max_retries must be an Integer of 0 or more, got #{value.inspect}"
      end

      def choice(name, value, choices)
        symbol = value.is_a?(String) ? value.to_sym : value
        return symbol if choices.include?(symbol)

        raise ConfigurationError,
          "adapter :openai_compatible #{name} must be one of #{choices.join(', ')}, got #{value.inspect}"
      end
    end
  end
end
