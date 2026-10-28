# frozen_string_literal: true

module Squishling
  class Run
    # Stops a call whose token budget is spent, before it makes another request.
    module Budgeting
      private

      # Raises BudgetExhaustedError when the call has spent its token budget (see Budget), before another request.
      # attempts is how many were made so far, models the ones tried, rejected the last [raw content, errors].
      def check_budget!(attempts: 0, models: nil, rejected: nil)
        exhausted = @client.exhausted_budget
        return unless exhausted

        error = BudgetExhaustedError.new(**exhausted, errors: rejected&.last || [], raw: rejected&.first,
          attempts: (attempts if attempts.positive?), models: (models.dup if models&.any?))
        log("stopped, #{error.errors.first}")
        raise error
      end
    end
  end
end
