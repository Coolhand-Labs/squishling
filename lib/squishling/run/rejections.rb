# frozen_string_literal: true

module Squishling
  class Run
    # What a Run records about a rejected reply: the error it raises and the reason it logs.
    module Rejections
      private

      def invalid_output(response, errors, attempt, models, source = "LLM")
        InvalidOutputError.new(errors:, raw: response.content, attempts: attempt, models:, source:,
          finish_reason: response.finish_reason)
      end

      # Why an attempt was rejected, for the log: the output check's errors, plus a note when the reply was cut off.
      def rejection_reason(errors, response)
        reason = errors.join("; ")
        response.truncated? ? "#{reason} (#{InvalidOutputError::CUTOFF_NOTE})" : reason
      end
    end
  end
end
