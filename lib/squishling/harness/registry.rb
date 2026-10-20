# frozen_string_literal: true

module Squishling
  class Harness
    # The harness types by name: the built-ins, registered as they load, and your own (Squishling.register_harness).
    module Registry
      STORE = NamedRegistry.new("harness")
      private_constant :STORE

      class << self
        def register_built_in(name, klass)
          STORE.register_built_in(name, klass)
        end

        # Registers a harness class (or a block, which becomes the body of a Base subclass) under a name.
        def register(name, klass = nil, &block)
          raise ConfigurationError, "register_harness takes a class or a block, not both" if klass && block
          raise ConfigurationError, "register_harness needs a Harness::Base subclass or a block" unless klass || block

          name = STORE.checked_name(name)
          klass = Class.new(Base, &block) if block
          Base.check_registrable!(klass, name)
          STORE.add(name, klass)
        end

        def fetch(name)
          STORE.fetch(name)
        end

        def names
          STORE.names
        end

        # Forgets the registered harnesses; the built-ins stay.
        def reset!
          STORE.reset!
        end
      end
    end
  end
end
