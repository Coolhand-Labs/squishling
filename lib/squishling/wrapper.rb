# frozen_string_literal: true

module Squishling
  # Module prepended to a squishling class. It intercepts squished methods regardless of
  # whether they're defined before or after the `squish` declaration (or at all).
  class Wrapper < Module
    def wrap(name)
      return if instance_methods(false).include?(name)

      define_method(name) do |*args, **kwargs, &block|
        impl =
          if defined?(super)
            -> { super(*args, **kwargs, &block) }
          else
            -> { raise NotImplementedError, "#{self.class}##{name} has no implementation" }
          end

        Router.dispatch(self, name, args, kwargs, impl)
      end
    end

    def inspect
      "#<Squishling::Wrapper>"
    end
  end
end
