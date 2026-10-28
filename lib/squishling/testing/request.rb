# frozen_string_literal: true

module Squishling
  module Testing
    # Run's follow-up messages (a private constant of Run): the helpers read what was sent through their parsers.
    MESSAGES = Run.const_get(:Messages)
    private_constant :MESSAGES

    # One provider request as the test adapter saw it: what left the process, and what came back.
    #
    # arguments and context are the method's arguments and the squish_context / squish! context values the model was
    # sent. For a judge they are those of the call being judged, and candidates holds the two samples. messages is
    # the conversation as sent (empty for a System One judgment, whose payload is the input). conversation is the
    # index of the chat in Adapter#conversations (nil for a judgment): a retry is the same conversation, an
    # escalation a new one. reply is the Adapter::Response, or the error raised instead.
    Request = Data.define(:label, :type, :role, :sample, :attempt, :attempts, :model, :provider, :params,
      :system_prompt, :output_schema, :messages, :conversation, :payload, :reply) do
      def arguments
        input["arguments"]
      end

      def context
        input["context"]
      end

      def candidates
        payload["candidates"]
      end

      # The validation messages this request carried back to the model: a retry in the same conversation, or an
      # escalation to the next step. Empty for a first attempt.
      def errors
        (retry_errors || escalation&.errors) || []
      end

      # The rejected output forwarded from the previous step (text, capped), or nil when none was.
      def forwarded_rejected
        escalation&.rejected
      end

      def failed?
        reply.is_a?(Exception)
      end

      def judge?
        role == :judge
      end

      # The JSON payload of the first user message, parsed (an escalation message wraps it in its own text).
      def self.payload_of(messages)
        text = messages.first.fetch(:content)
        JSON.parse(MESSAGES.parse_escalation(text)&.input || text)
      rescue JSON::ParserError
        {}
      end

      private

      # The method's arguments and context: the payload itself, or inside a judge's "input".
      def input
        judge? ? payload.fetch("input", {}) : payload
      end

      def retry_errors
        text = messages.last&.fetch(:content, nil)
        messages.size > 1 && text ? MESSAGES.parse_retry(text) : nil
      end

      def escalation
        text = messages.first&.fetch(:content, nil)
        text && MESSAGES.parse_escalation(text)
      end
    end
  end
end
