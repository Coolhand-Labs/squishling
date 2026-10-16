# frozen_string_literal: true

module Squishling
  class Run
    # The follow-up messages a Run sends a model after an output was rejected.
    module Messages
      private

      def retry_message(errors)
        "Your previous response was rejected:\n- #{errors.join("\n- ")}\nRespond again with corrected JSON only."
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
        "#{input}\n\nA previous attempt at this request returned:\n#{previous}\n" \
          "It was rejected:\n- #{errors.join("\n- ")}\nRespond with corrected JSON only."
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
