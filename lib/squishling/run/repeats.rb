# frozen_string_literal: true

module Squishling
  class Run
    # Which attempt follows a rejected one. A model that sends back the reply it was just told was invalid, in the
    # same chat, would do it again, so a repeated reply gives up on the rest of its step's attempts.
    module Repeats
      private

      # The number of the attempt after attempt in path, or nil when none is left.
      def next_attempt(path, attempt, repeated)
        return (attempt + 1 if attempt < path.size) unless repeated

        skipped = path.drop(attempt).index { |step| step != path[attempt - 1] }
        attempt + skipped + 1 if skipped
      end
    end
  end
end
