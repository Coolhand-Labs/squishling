# frozen_string_literal: true

module Squishling
  module Testing
    # The test-facing helpers, shared by the Minitest and RSpec mixins. A mixin supplies #squishling_failure(message),
    # which fails the current test.
    module Helpers
      # Installs a scripted adapter and returns it. The block scripts it (see Script); the adapter's #requests,
      # #conversations and #arguments show what was sent.
      def fake_squishling(&)
        Testing.install(&)
      end

      # Any LLM request raises until a test installs a fake, naming the squished method that made it.
      def forbid_provider_calls!
        Testing.forbid_provider_calls!
      end

      def assert_sent_arguments(source, expected, request: 0)
        failure = Checks.sent_arguments(source, expected, request:)
        squishling_failure(failure) if failure
      end

      def assert_llm_calls(source, expected)
        failure = Checks.call_count(source, expected)
        squishling_failure(failure) if failure
      end

      def assert_no_llm_call(&)
        failure = Checks.no_llm_call(&)
        squishling_failure(failure) if failure
      end

      def stub_squishling_result(klass, attrs = nil, **, &)
        Testing.stub_result(klass, attrs, **, &)
      end

      def stub_squishling_error(klass, kind, **, &)
        Testing.stub_error(klass, kind, **, &)
      end

      def squishling_validate(klass, reply, **inputs)
        Testing.validate(klass, reply, **inputs)
      end

      def squishling_fallback_for(klass, error, **inputs)
        Testing.fallback_for(klass, error, **inputs)
      end

      def squishling_preview(klass, **inputs)
        Testing.preview(klass, **inputs)
      end

      def valid_reply_for(source, **overrides)
        Testing.valid_reply_for(source, **overrides)
      end

      def invalid_reply_for(source, **)
        Testing.invalid_reply_for(source, **)
      end

      def capture_squawk
        Testing.capture_squawk
      end

      def with_squawk(capture = capture_squawk, &)
        Testing.with_squawk(capture, &)
      end
    end
  end
end
