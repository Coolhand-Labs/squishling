# frozen_string_literal: true

module Squishling
  module Testing
    # A scripted answer with more than content: the model id the provider reports and its token counts, so the
    # squawk and observer usage paths are covered. usage is a Hash such as { input_tokens: 12, output_tokens: 30 }.
    class Reply
      attr_reader :content, :model, :usage

      def initialize(content = nil, model: nil, usage: nil)
        @content = content
        @model = model
        @usage = usage
      end
    end

    # A scripted provider failure, named by what went wrong (see Failures).
    Failure = Data.define(:intent)

    # The answer to the "winner" question of a System One judgment.
    Answer = Struct.new(:choice, :probabilities)

    # What Adapter#judge returns: answers by question name, like RubyLLM's Judgment.
    Judgment = Struct.new(:answers) do
      def [](name)
        answers[name]
      end
    end

    # The provider failures a script can name by intent rather than by the error class of any one SDK. Each becomes
    # the Squishling error an adapter raises for it: LLMError for what is worth another attempt, ConfigurationError
    # for what is not. Messages carry the failure and its status, like the real adapters' do.
    module Failures
      # intent => [error class, what happened, HTTP status or nil]
      INTENTS = {
        rate_limit: [LLMError, "rate limited", 429],
        server_error: [LLMError, "server error", 500],
        overloaded: [LLMError, "provider overloaded", 529],
        timeout: [LLMError, "request timed out", nil],
        context_length: [LLMError, "context length exceeded", 400],
        bad_request: [ConfigurationError, "bad request", 400],
        unauthorized: [ConfigurationError, "unauthorized", 401],
        forbidden: [ConfigurationError, "forbidden", 403]
      }.freeze

      module_function

      def check!(intent)
        return intent if INTENTS.key?(intent)

        raise ArgumentError, "unknown failure #{intent.inspect} (one of #{INTENTS.keys.map(&:inspect).join(', ')})"
      end

      def build(intent, label)
        klass, text, status = INTENTS.fetch(intent)
        klass.new("#{label}: #{text}#{" (HTTP #{status})" if status}")
      end
    end
  end
end
