# frozen_string_literal: true

module Squishling
  module Testing
    # The assertions, independent of any test framework: each returns a failure message, or nil when it holds. The
    # Minitest and RSpec mixins turn a message into a failure in their own way.
    module Checks
      module_function

      # The requests of a fake adapter (or an Array of them) sent exactly these arguments, as JSON would carry them.
      def sent_arguments(source, expected, request: 0)
        sent = requests_of(source)[request]
        return "expected request ##{request} to have been sent, but only #{requests_of(source).size} were" unless sent

        wanted = Schema.jsonify(expected)
        return nil if sent.arguments == wanted

        "expected the model to be sent arguments #{wanted.inspect}, but it was sent #{sent.arguments.inspect}"
      end

      def call_count(source, expected)
        actual = requests_of(source).size
        actual == expected ? nil : "expected #{expected} LLM call(s), but there were #{actual}"
      end

      # Runs the block with provider calls forbidden: a failure message when it tried to make one.
      def no_llm_call(&)
        attempts = Testing.no_llm_call(&)
        return nil if attempts.empty?

        "expected no LLM call, but #{attempts.uniq.join(', ')} reached the provider (#{attempts.size} request(s))"
      end

      def requests_of(source)
        source.respond_to?(:requests) ? source.requests : Array(source)
      end
    end
  end
end
