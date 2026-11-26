# frozen_string_literal: true

module Squishling
  # Classes by name, for the things that can be registered (harnesses, adapters): the built-ins, registered as they
  # load, and the developer's own. Shared across threads, so every read and write is under the lock.
  class NamedRegistry
    NAME = /\A[a-z][a-z0-9_]*\z/

    # kind names what is registered ("harness"), for messages.
    def initialize(kind)
      @kind = kind
      @lock = Mutex.new
      @built_in = {}
      @custom = {}
    end

    def register_built_in(name, klass)
      @lock.synchronize { @built_in[name] = klass }
    end

    # The name as a Symbol. Raises ConfigurationError when it isn't a Symbol or String of lowercase letters, digits
    # and underscores, starting with a letter.
    def checked_name(name)
      unless name.is_a?(Symbol) || name.is_a?(String)
        raise ConfigurationError, "#{@kind} name must be a Symbol or String, got #{name.inspect}"
      end

      name = name.to_sym
      return name if NAME.match?(name)

      raise ConfigurationError,
        "#{@kind} name #{name.inspect} must be lowercase letters, digits, and underscores, starting with a letter"
    end

    # Registers klass under name (already checked), unless the name is taken.
    def add(name, klass)
      @lock.synchronize do
        raise ConfigurationError, "#{@kind} #{name.inspect} is already registered" if taken?(name)

        @custom[name] = klass
      end
      klass
    end

    def fetch(name)
      @lock.synchronize { @built_in[name] || @custom[name] }
    end

    def names
      @lock.synchronize { @built_in.keys + @custom.keys }
    end

    # Forgets the registered classes; the built-ins stay.
    def reset!
      @lock.synchronize { @custom.clear }
    end

    private

    def taken?(name)
      @built_in.key?(name) || @custom.key?(name)
    end
  end
end
