# frozen_string_literal: true

module Squishling
  # A call id the caller supplies (Squishling.with_call_id), in place of the UUID Squishling generates. It names the
  # first squished call started inside the block (whether that call then runs Ruby or the LLM), so within the block
  # each call id and "<call_id>.<n>" request id stays unique; across blocks that is the caller's job. Fiber-local like
  # the Router's frames.
  module CallId
    KEY = :__squishling_call_id__

    # Leaves room for ".<n>" under Coolhand's 255-character limit on a client id.
    MAX_LENGTH = 250

    # Control and format characters (zero-width, bidi marks), and line and paragraph separators.
    INVISIBLE = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/

    EDGE_SPACE = /\A[[:space:]]|[[:space:]]\z/

    Scope = Struct.new(:id, :claimed)
    private_constant :Scope

    module_function

    # Runs the block with id waiting to be claimed by the first squished call it starts. Returns the block's value.
    def with(id)
      scope = Scope.new(validate(id), false)
      previous = Thread.current[KEY]
      begin
        Thread.current[KEY] = scope
        yield
      ensure
        Thread.current[KEY] = previous
      end
    end

    # The supplied id the first time it is asked for inside a with block, nil after that and outside one.
    def claim
      scope = Thread.current[KEY]
      return if scope.nil? || scope.claimed

      scope.claimed = true
      scope.id
    end

    # The id as a frozen UTF-8 String. Coolhand drops a client id that is blank, over 255 characters, or has control
    # or invisible characters, so they are refused here, where the mistake can be seen.
    def validate(id)
      text = utf8(id)
      return text.freeze if text && acceptable?(text)

      raise ConfigurationError, "with_call_id needs a String of 1-#{MAX_LENGTH} characters with no surrounding " \
                                "whitespace or control or invisible characters, got #{Appendices.describe(id)}"
    end

    def utf8(id)
      text = id.encode(Encoding::UTF_8) if id.is_a?(String)
      text if text&.valid_encoding? # encoding to the same encoding doesn't check it
    rescue EncodingError
      nil
    end
    private_class_method :utf8

    def acceptable?(text)
      !text.empty? && text.length <= MAX_LENGTH && !text.match?(EDGE_SPACE) && !text.match?(INVISIBLE)
    end
    private_class_method :acceptable?
  end
end
