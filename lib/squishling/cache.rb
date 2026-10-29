# frozen_string_literal: true

module Squishling
  # Prompt caching: whether a request asks the provider to cache the stable prompt (the purpose and the input note in
  # the system prompt), layered config -> class -> method -> squish! like generation params, and per escalation step.
  # A level declares true, false, or a Hash of options (ttl: "1h"), and nil leaves it to the level above. What a
  # request carries is false (no cache controls) or a Hash of options ({} for the provider's default). See
  # docs/configuration.md.
  module Cache
    module_function

    # One level's value, validated: nil (inherit), true, false, or a frozen Hash with Symbol keys. Explicit provider
    # caches (id:) are not supported: an adapter holds no state between requests.
    def normalize(value, label)
      return value if value.nil? || [true, false].include?(value)
      unless value.is_a?(Hash)
        raise ConfigurationError, "#{label} must be true, false, or a Hash of options, got #{value.inspect}"
      end

      options = value.transform_keys(&:to_sym)
      raise ConfigurationError, "#{label}: id: (an explicit provider cache) isn't supported" if options.key?(:id)

      options.freeze
    end

    # What the request carries: the last level that declares a value wins (a Hash replaces, it doesn't merge), and no
    # level at all means off. true is the provider's default options.
    def resolve(*layers)
      value = layers.reverse.find { |layer| !layer.nil? }
      value == true ? {}.freeze : value || false
    end
  end
end
