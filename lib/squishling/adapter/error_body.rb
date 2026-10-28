# frozen_string_literal: true

module Squishling
  module Adapter
    # Reads the machine-readable fields of a provider's error body: the status (OpenAI-style `type`, Gemini's
    # `status`), the code, and the name of the field it objected to. Only short plain tokens come out; the message
    # and anything else a provider might echo from the request never do.
    module ErrorBody
      # A status or code is an enumeration-like word (no hyphens, so an API key like sk-... never passes); a param is
      # a field path (messages[0].content), which is only compared with the developer's own param names and never
      # repeated.
      WORD = /\A[A-Za-z0-9][\w.]{0,39}\z/
      PATH = /\A[\w.\-\[\]]{1,64}\z/
      private_constant :WORD, :PATH

      module_function

      # body: a JSON String, a Hash with String keys, or an Array wrapping the Hash (Gemini does that). http_status
      # drops a code that only repeats it. Returns { status:, code:, param: }, each a String or nil.
      def read(body, http_status: nil)
        detail = error(body)
        return { status: nil, code: nil, param: nil } unless detail

        code = token(detail["code"], WORD)
        { status: token(detail["status"], WORD) || token(detail["type"], WORD),
          code: (code unless code == http_status.to_s),
          param: token(detail["param"], PATH) }
      end

      # The body's `error` Hash, or nil when it has none (or isn't JSON). For adapters that need more of it than
      # #read returns, e.g. to recognize a wording; they must not repeat it.
      def error(body)
        data = body.is_a?(String) ? JSON.parse(body.dup.force_encoding(Encoding::UTF_8)) : body
        data = data.first if data.is_a?(Array)
        detail = data["error"] if data.is_a?(Hash)
        detail if detail.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end

      def token(value, pattern)
        value = value.to_s if value.is_a?(Integer)
        value if value.is_a?(String) && value.match?(pattern)
      end
    end
  end
end
