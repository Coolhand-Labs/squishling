# frozen_string_literal: true

require "uri"

module Squishling
  module Adapters
    # Checks the options of Adapters::OpenAICompatible, raising ConfigurationError (without echoing a value that may
    # be a secret) for a bad one.
    module OpenAIOptions
      # The URL itself is never in the message: it may carry credentials.
      INVALID_BASE_URL = "adapter :openai_compatible base_url must be an http(s) URL without credentials (use " \
                         "api_key:), a query, or a fragment"
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

      def default_model(model)
        return nil if model.nil?
        return model.to_s if (model.is_a?(String) || model.is_a?(Symbol)) && !model.to_s.strip.empty?

        raise ConfigurationError, "adapter :openai_compatible default_model must be a model name, got #{model.inspect}"
      end

      def number(name, value)
        return value if value.is_a?(Numeric) && value.positive?

        raise ConfigurationError, "adapter :openai_compatible #{name} must be a positive number, got #{value.inspect}"
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
