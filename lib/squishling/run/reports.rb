# frozen_string_literal: true

module Squishling
  class Run
    # What a Run tells the squawk hook (see Squawk): the report of each attempt, and the one final report of a call that
    # a token budget or a disagreement stopped.
    module Reports
      # Reports to squawk the BudgetExhaustedError or DisagreementError that stopped the call: one final report with
      # the error, for an ending that no attempt of its own reported (the attempt before a budget stop was already
      # reported, as not final, and a disagreement's samples were both accepted). Nothing was sent, so there is no
      # output, and the provider and params are unknown (the stop comes from the harness, not from a step).
      # Internal: Invoker calls it once, whatever the harness, so a custom harness has nothing to do.
      def report_stop(error)
        hook = @definition.squawk
        attempts = error.attempts.to_i
        return unless hook && Squawk.report?(@definition.squawk_on, attempts, error, true)

        metadata = squawk_metadata(
          attempt: attempts, attempts:, final: true, repeated: false, model: error.models&.last, provider: nil,
          params: nil, input: @prompt.input, response: nil, role: nil, sample: nil,
          stopped: error.is_a?(BudgetExhaustedError) ? :budget : :disagreement
        )
        Squawk.call(hook, output: nil, metadata:, error:)
      end

      private

      # Runs the observability hook, if any, with this attempt's raw output (nil when the call itself failed),
      # the error that ended it (nil when it was accepted), and what was asked. role is nil for escalation
      # attempts, :sample (with the sample's name) or :judge. reask is whether the attempt retried in the same chat,
      # repeated whether it sent back the reply the attempt before it was rejected for, and final whether no attempt
      # follows it.
      def squawk(prompt, path, attempt, response, error, sample: nil, reask: false, repeated: false,
        final: attempt == path.size)
        hook = @definition.squawk
        return unless hook && Squawk.report?(@definition.squawk_on, attempt, error, final)

        step = path[attempt - 1]
        metadata = squawk_metadata(
          attempt:, attempts: path.size, final:, repeated:, model: response&.model || step.model,
          provider: step.provider, params: step.request_params(reask), input: prompt.input, response:,
          role: sample ? :sample : prompt.role, sample: sample&.name
        )
        Squawk.call(hook, output: response&.content, metadata:, error:)
      end

      def squawk_metadata(attempt:, attempts:, final:, repeated:, model:, provider:, params:, input:, response:,
        role:, sample:, stopped: nil)
        {
          label:, attempt:, attempts:, final:, repeated:, model:, provider:, params:, input:,
          usage: response&.usage, finish_reason: response&.finish_reason, role:, sample:, stopped:
        }
      end
    end
  end
end
