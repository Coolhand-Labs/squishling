# frozen_string_literal: true

module Squishling
  module Testing
    # What a test asked apprentice mode to record: every shadow run's report, with the report hook's keywords (the
    # Ruby result, the LLM's, whether they matched, the error that ended it, the inputs, and metadata). Use
    # Testing.with_apprentice, which records the reports whichever report hook the class declares.
    class ApprenticeCapture
      Report = Data.define(:ruby, :llm, :match, :error, :inputs, :metadata)

      def initialize
        @lock = Mutex.new
        @reports = []
      end

      # Shadow runs on a background runner report from its threads, so this is taken under a lock.
      def call(ruby: nil, llm: nil, match: nil, error: nil, inputs: nil, metadata: nil)
        report = Report.new(ruby:, llm:, match:, error:, inputs:, metadata:)
        @lock.synchronize { @reports << report }
      end

      def reports
        @lock.synchronize { @reports.dup }
      end
    end
  end
end
