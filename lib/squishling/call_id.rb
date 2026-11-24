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

    # Declared ids remembered per method, to warn once when one repeats.
    REPEAT_MEMORY = 1_000

    LOCK = Mutex.new
    private_constant :LOCK

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

    # A call_id: declaration (squishling call_id:, squish call_id:): the name of an input (a Symbol), a Proc that gets
    # the inputs as keywords (instance_exec'd on the receiver), false to turn off an inherited one, or nil to leave it
    # unset.
    def normalize_source(source, where)
      return source if source.nil? || source == false || source.is_a?(Symbol) || source.is_a?(Proc)

      raise ConfigurationError, "#{where} call_id: must be the name of an input (a Symbol), a Proc, or false, " \
                                "got #{Appendices.describe(source)}"
    end

    # The id a declaration gives one call: the input's value, or the Proc's, as a String; nil (a generated UUID) when
    # that is nil, or nil when there is no declaration. Raises ConfigurationError when it isn't an acceptable id (see
    # #validate). label names the method.
    def declared(source, receiver, inputs, label)
      return unless source

      value = source.is_a?(Proc) ? receiver.instance_exec(**inputs, &source) : inputs[source]
      return if value.nil?

      id = validate(value.is_a?(Symbol) || value.is_a?(Numeric) ? value.to_s : value, "#{label} call_id:")
      warn_if_repeated(label, id)
      id
    end

    # Forgets the declared ids seen so far, and the methods already warned about. For specs; not public API.
    def reset! # :nodoc:
      LOCK.synchronize do
        @seen = {}
        @warned = {}
      end
    end

    # The id as a frozen UTF-8 String. Coolhand drops a client id that is blank, over 255 characters, or has control
    # or invisible characters, so they are refused here, where the mistake can be seen.
    def validate(id, what = "with_call_id")
      text = utf8(id)
      return text.freeze if text && acceptable?(text)

      raise ConfigurationError, "#{what} needs a String of 1-#{MAX_LENGTH} characters with no surrounding " \
                                "whitespace or control or invisible characters, got #{Appendices.describe(id)}"
    end

    # Logs, once per method, that a declared id came up again: its request ids then repeat, which makes feedback sent
    # by client_unique_id ambiguous. Remembers the last REPEAT_MEMORY ids per method until it has warned. The log line
    # names the method, never the id.
    def warn_if_repeated(label, id)
      return unless LOCK.synchronize { repeat?(label, id) }

      Squishling.config.logger&.warn(
        "[Squishling] #{label} call_id: gave an id a second time, so its request ids repeat and feedback by " \
        "client_unique_id can't tell the calls apart; declare an id that is unique to each call"
      )
    end
    private_class_method :warn_if_repeated

    def repeat?(label, id)
      @seen ||= {}
      @warned ||= {}
      return false if @warned.key?(label)

      seen = (@seen[label] ||= {})
      if seen.key?(id)
        @seen.delete(label)
        return @warned[label] = true
      end

      seen.shift if seen.size >= REPEAT_MEMORY
      seen[id] = true
      false
    end
    private_class_method :repeat?

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
