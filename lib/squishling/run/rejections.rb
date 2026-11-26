# frozen_string_literal: true

module Squishling
  class Run
    # What a Run does with a reply it rejects: the attempt that follows, the error it raises, the reason it logs, and
    # the token budget that can end the call before another request. A model that sends back the reply it was just told
    # was invalid, in the same chat, would do it again, so a repeated reply gives up on the rest of its step's attempts.
    module Rejections
      private

      # The number of the attempt after attempt in path, or nil when none is left.
      def next_attempt(path, attempt, repeated)
        return (attempt + 1 if attempt < path.size) unless repeated

        skipped = path.drop(attempt).index { |step| step != path[attempt - 1] }
        attempt + skipped + 1 if skipped
      end

      def invalid_output(response, errors, attempt, models, source = "LLM")
        InvalidOutputError.new(errors:, raw: response.content, attempts: attempt, models:, source:,
          finish_reason: response.finish_reason)
      end

      # Why an attempt was rejected, for the log: the output check's errors, plus a note when the reply was cut off.
      def rejection_reason(errors, response)
        reason = errors.join("; ")
        response.truncated? ? "#{reason} (#{InvalidOutputError::CUTOFF_NOTE})" : reason
      end

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
