# frozen_string_literal: true

module Squishling
  # `include Squishling` puts its methods ahead of inherited ones, so a class that inherits a method of the same
  # name (Sinatra::Base.call, a parent's own `purpose`, ...) would be silently shadowed. Methods the class
  # defines itself always win, so they are never reported.
  module Collisions
    INSTANCE_METHODS = %i[squish! squishling_result].freeze

    module_function

    # Raises ConfigurationError naming every inherited method Squishling would override. Call it before
    # extending the class with ClassMethods, and after the module is in the class's ancestors.
    def check!(base)
      found = class_collisions(base) + instance_collisions(base)
      return if found.empty?

      raise ConfigurationError,
        "#{base} inherits methods that Squishling would override: #{found.join(', ')}. " \
        "Include Squishling in a plain Ruby class instead (compose the framework object rather than inheriting it)"
    end

    def class_collisions(base)
      ClassMethods.public_instance_methods(false).filter_map do |name|
        next if name == :inherited || !base.respond_to?(name, true)

        owner = base.method(name).owner
        next if owner == base.singleton_class || owner == ClassMethods

        "#{base}.#{name} (from #{describe(owner)})"
      end
    end

    def instance_collisions(base)
      ancestors = base.ancestors
      inherited = ancestors.drop(ancestors.index(Squishling) + 1)

      INSTANCE_METHODS.filter_map do |name|
        next if defined_in?(base, name)

        owner = inherited.find { |mod| defined_in?(mod, name) }
        "#{base}##{name} (from #{describe(owner)})" if owner
      end
    end

    def defined_in?(mod, name)
      mod.method_defined?(name, false) || mod.private_method_defined?(name, false)
    end

    def describe(owner)
      owner.singleton_class? ? "#{owner.attached_object}'s class methods" : owner.to_s
    end
  end
end
