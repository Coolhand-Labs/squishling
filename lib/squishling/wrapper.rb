# frozen_string_literal: true

module Squishling
  # Module prepended to a squishling class. It intercepts squished methods regardless of
  # whether they're defined before or after the `squish` declaration (or at all).
  class Wrapper < Module
    # The method beneath any Squishling wrappers (instance_method resolves to the prepended wrapper first),
    # or nil when the method has no implementation.
    def self.implementation(method)
      method = method.super_method while method&.owner.is_a?(Wrapper)
      method
    end

    def wrap(name)
      return if method_defined?(name, false)

      wrapper = self
      define_method(name) do |*args, **kwargs, &block|
        impl =
          if defined?(super)
            -> { super(*args, **kwargs, &block) }
          else
            -> { raise NotImplementedError, "#{self.class}##{name} has no implementation" }
          end

        Router.dispatch(self, name, args, kwargs, impl, wrapper:)
      end
    end

    def inspect
      "#<Squishling::Wrapper>"
    end
  end
end
