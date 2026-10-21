# frozen_string_literal: true

module Squishling
  module Testing
    # The helpers for RSpec (no rspec-mocks needed): `config.include Squishling::Testing::RSpec`, or include it in a
    # group. What it installs (the adapter, observer, and stubs) is put back after each example.
    #
    #   RSpec.describe RegexInferrer do
    #     it "retries a bad regex" do
    #       fake = fake_squishling { |llm| llm.step(:any).reply({ regex: "[bad(" }, { regex: "Run.*" }) }
    #       expect(described_class.call(sample_turns: turns).regex).to eq("Run.*")
    #       assert_sent_arguments fake, { sample_turns: turns }
    #     end
    #   end
    module RSpec
      include Helpers

      def self.included(group)
        super
        group.after { Testing.reset! }
      end

      private

      def squishling_failure(message)
        raise ::RSpec::Expectations::ExpectationNotMetError, message
      end
    end
  end
end
