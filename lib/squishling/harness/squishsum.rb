# frozen_string_literal: true

module Squishling
  class Harness
    # Two samples on the escalation's first step, asked concurrently. Identical outputs (or ones compare: calls
    # equal) are accepted; different ones raise DisagreementError.
    class Squishsum < Base
      option :compare, :proc

      def call(run, compare: nil)
        stage = run.stages.first
        first, second = run.samples([stage, stage])
        return first if run.agree?(first, second, compare)

        run.log("samples disagreed")
        raise DisagreementError.new(candidates: [first, second], models: [stage.first.model] * 2)
      end
    end

    Registry.register_built_in(:squishsum, Squishsum)
  end
end
