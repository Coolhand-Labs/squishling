# frozen_string_literal: true

module Squishling
  # Every class that includes Squishling (and each subclass of one), so they can be verified ahead of runtime.
  # Held weakly, so classes replaced by code reloading (e.g. Rails in development) can be collected; a class that is
  # replaced but not yet collected is left out of the list. Shared across threads, so every access is under the lock.
  module ClassRegistry
    LOCK = Mutex.new
    GONE = Object.new.freeze
    UNKNOWN = Object.new.freeze
    private_constant :LOCK, :GONE, :UNKNOWN

    @classes = ObjectSpace::WeakMap.new

    class << self
      def register(klass)
        LOCK.synchronize { @classes[klass] = true }
        klass
      end

      # The live classes, in no particular order, as a snapshot.
      def classes
        LOCK.synchronize { @classes.keys }.reject { |klass| replaced?(klass) }
      end

      # Forgets every class, e.g. between specs.
      def reset!
        LOCK.synchronize { @classes = ObjectSpace::WeakMap.new }
      end

      private

      # A named class whose constant is gone or now holds another object (a reload has replaced it). Anonymous
      # classes have no constant to go stale, and a name that can't be walked (under an anonymous module, a temporary
      # name) is taken as live.
      def replaced?(klass)
        name = Module.instance_method(:name).bind_call(klass) # the class may define its own .name
        return false unless name

        found = lookup(name)
        !found.equal?(UNKNOWN) && !found.equal?(klass)
      end

      def lookup(name)
        name.split("::").reduce(Object) do |scope, constant|
          found = child(scope, constant)
          return found if found.equal?(GONE) || found.equal?(UNKNOWN)

          found
        end
      end

      # The constant in scope, without autoloading it: GONE when it is missing or a pending autoload (Zeitwerk resets
      # a reloaded constant to one, and loading it would run app code), UNKNOWN when the name can't be walked.
      def child(scope, constant)
        return UNKNOWN unless scope.is_a?(Module) && constant.match?(/\A[A-Z]\w*\z/)
        return GONE if scope.autoload?(constant, false) || !scope.const_defined?(constant, false)

        scope.const_get(constant, false)
      end
    end
  end
end
