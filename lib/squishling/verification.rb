# frozen_string_literal: true

module Squishling
  # What Squishling.verify found: the problems in the squished classes' setup, none when it is sound.
  module Verification
    # One thing wrong. label names where ("Triage#call", or "adapter" for a setup that isn't one class's).
    Problem = Data.define(:label, :message) do
      # The existing messages already start with the label; say it once.
      def to_s
        message.start_with?(label) ? message : "#{label}: #{message}"
      end
    end

    class Report
      attr_reader :problems

      def initialize(problems)
        @problems = problems.dup.freeze
        freeze
      end

      def ok?
        problems.empty?
      end

      def size
        problems.size
      end

      # A lint-style listing, one problem per line.
      def to_s
        return "Squishling: no problems found" if ok?

        lines = problems.map { |problem| "  #{problem}" }
        "Squishling found #{size} #{size == 1 ? 'problem' : 'problems'}:\n#{lines.join("\n")}"
      end
    end
  end
end
