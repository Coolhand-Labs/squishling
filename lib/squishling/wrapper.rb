# frozen_string_literal: true

module Squishling
  # Module prepended to a squishling class. It intercepts squished methods regardless of
  # whether they're defined before or after the `squish` declaration (or at all).
  class Wrapper < Module
    # Backtrace locations report real paths, so resolve this one too (a symlinked install keeps __FILE__ as given).
    FILE = File.realpath(__FILE__)
    private_constant :FILE

    # Raised by the wrapper when a squished method has no implementation at all.
    class NoImplementation < NotImplementedError; end
    private_constant :NoImplementation

    # Whether a NotImplementedError is the "no implementation" signal rather than an error from called code: the
    # wrapper's own, or one raised directly in the method's own frame (`def x = raise NotImplementedError`). The
    # implementation lambda below sits one frame above the method, so anything raised deeper (a helper, a block,
    # another object, a `super` into an unsquished parent) has more frames in between. A missing backtrace fails
    # closed; an exception re-raised or reused keeps the backtrace of its first raise.
    def self.stub?(error)
      error.is_a?(NoImplementation) || error.backtrace_locations&.at(1)&.absolute_path == FILE
    end

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
            -> { raise NoImplementation, "#{self.class}##{name} has no implementation" }
          end

        Router.dispatch(self, name, args, kwargs, impl, wrapper:)
      end
    end

    def inspect
      "#<Squishling::Wrapper>"
    end
  end
end
