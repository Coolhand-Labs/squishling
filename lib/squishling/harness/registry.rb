# frozen_string_literal: true

module Squishling
  class Harness
    # The harness types by name: the built-ins, registered as they load, and your own (Squishling.register_harness).
    # Shared across threads, so every read and write is under the lock.
    module Registry
      NAME = /\A[a-z][a-z0-9_]*\z/

      LOCK = Mutex.new
      private_constant :LOCK
      @built_in = {}
      @custom = {}

      class << self
        def register_built_in(name, klass)
          LOCK.synchronize { @built_in[name] = klass }
        end

        # Registers a harness class (or a block, which becomes the body of a Base subclass) under a name.
        def register(name, klass = nil, &block)
          raise ConfigurationError, "register_harness takes a class or a block, not both" if klass && block
          raise ConfigurationError, "register_harness needs a Harness::Base subclass or a block" unless klass || block

          name = checked_name(name)
          klass = Class.new(Base, &block) if block
          Base.check_registrable!(klass, name)
          LOCK.synchronize do
            raise ConfigurationError, "harness #{name.inspect} is already registered" if taken?(name)

            @custom[name] = klass
          end
          klass
        end

        def fetch(name)
          LOCK.synchronize { @built_in[name] || @custom[name] }
        end

        def names
          LOCK.synchronize { @built_in.keys + @custom.keys }
        end

        # Forgets the registered harnesses; the built-ins stay.
        def reset!
          LOCK.synchronize { @custom.clear }
        end

        private

        def checked_name(name)
          unless name.is_a?(Symbol) || name.is_a?(String)
            raise ConfigurationError, "a harness name must be a Symbol or String, got #{name.inspect}"
          end

          name = name.to_sym
          return name if NAME.match?(name)

          raise ConfigurationError,
            "harness name #{name.inspect} must be lowercase letters, digits, and underscores, starting with a letter"
        end

        def taken?(name)
          @built_in.key?(name) || @custom.key?(name)
        end
      end
    end
  end
end
