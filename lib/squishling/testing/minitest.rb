# frozen_string_literal: true

module Squishling
  module Testing
    # The helpers for Minitest: include it in a test case (or ActiveSupport::TestCase). What it installs (the
    # adapter, observer, and stubs) is put back after each test.
    #
    #   class RegexInferrerTest < Minitest::Test
    #     include Squishling::Testing::Minitest
    #
    #     def test_retries_a_bad_regex
    #       fake = fake_squishling { |llm| llm.step(:any).reply({ regex: "[bad(" }, { regex: "Run.*" }) }
    #       assert_equal "Run.*", RegexInferrer.call(sample_turns: turns).regex
    #       assert_sent_arguments fake, { sample_turns: turns }
    #     end
    #   end
    module Minitest
      include Helpers

      def after_teardown
        Testing.reset!
        super
      end

      private

      def squishling_failure(message)
        flunk message
      end
    end
  end
end
