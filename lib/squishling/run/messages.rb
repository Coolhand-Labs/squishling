# frozen_string_literal: true

module Squishling
  class Run
    # The follow-up messages a Run sends a model after an output was rejected.
    module Messages
      RETRY_HEAD = "Your previous response was rejected:\n- "
      RETRY_TAIL = "\nRespond again with corrected JSON only."
      RETURNED = "\n\nA previous attempt at this request returned:\n"
      REJECTED = "\nIt was rejected:\n- "
      ESCALATION_TAIL = "\nRespond with corrected JSON only."
      private_constant :RETRY_HEAD, :RETRY_TAIL, :RETURNED, :REJECTED, :ESCALATION_TAIL

      # What an escalation message carried: the original input, the (capped) rejected output text, and the errors.
      Escalation = Data.define(:input, :rejected, :errors)

      RETRY_PATTERN = /\A#{Regexp.escape(RETRY_HEAD)}(.*)#{Regexp.escape(RETRY_TAIL)}\z/m
      ESCALATION_PATTERN = Regexp.new(
        "\\A(.*?)#{Regexp.escape(RETURNED)}(.*)#{Regexp.escape(REJECTED)}(.*)#{Regexp.escape(ESCALATION_TAIL)}\\z",
        Regexp::MULTILINE
      )
      private_constant :RETRY_PATTERN, :ESCALATION_PATTERN

      class << self
        # The errors a retry message carries, or nil when text isn't one. The inverse of the message a Run sends, kept
        # here so the two can't drift apart (the test helpers read what was sent through it). Errors are told apart
        # by splitting on "\n- ", so one that itself contains that sequence reads back as several.
        def parse_retry(text)
          text.match(RETRY_PATTERN)&.then { |match| match[1].split("\n- ") }
        end

        # What an escalation message carried, or nil when text isn't one.
        def parse_escalation(text)
          match = text.match(ESCALATION_PATTERN)
          match && Escalation.new(input: match[1], rejected: match[2], errors: match[3].split("\n- "))
        end
      end

      private

      def retry_message(errors)
        "#{RETRY_HEAD}#{errors.join("\n- ")}#{RETRY_TAIL}"
      end

      # The first message to a fresh chat after an earlier model's output was rejected. The rejected output is
      # model-generated and may cross providers, so it is capped at Invoker::MAX_FORWARDED_CHARS.
      def escalation_message(input, raw, errors)
        previous = rejected_text(raw)
        previous = "(an empty response)" if previous.strip.empty? || raw.nil?
        if previous.length > Invoker::MAX_FORWARDED_CHARS
          omitted = previous.length - Invoker::MAX_FORWARDED_CHARS
          previous = "#{previous[0, Invoker::MAX_FORWARDED_CHARS]}... [truncated, #{omitted} more characters]"
        end
        "#{input}#{RETURNED}#{previous}#{REJECTED}#{errors.join("\n- ")}#{ESCALATION_TAIL}"
      end

      # The rejected output as text. Output that was rejected for being unrepresentable in JSON (Infinity, invalid
      # UTF-8) can't be serialized or measured as is, so it is scrubbed or replaced rather than raising.
      def rejected_text(raw)
        return utf8(raw).scrub("?") if raw.is_a?(String)

        JSON.generate(raw)
      rescue JSON::JSONError
        "(a response JSON can't represent)"
      end

      # A binary-tagged string counts every byte as valid, so it is read as UTF-8 before scrubbing.
      def utf8(text)
        text.encoding == Encoding::BINARY ? text.dup.force_encoding(Encoding::UTF_8) : text
      end
    end
  end
end
