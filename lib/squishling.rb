# frozen_string_literal: true

require "json"
require "json_schemer"
require "schematist"

require_relative "squishling/version"
require_relative "squishling/errors"
require_relative "squishling/configuration"
require_relative "squishling/params"
require_relative "squishling/named_registry"
require_relative "squishling/adapter/error_body"
require_relative "squishling/adapter"
require_relative "squishling/adapters/ruby_llm"
require_relative "squishling/adapters/openai_options"
require_relative "squishling/adapters/openai_compatible"
require_relative "squishling/squawk"
require_relative "squishling/observer"
require_relative "squishling/observers/coolhand"
require_relative "squishling/model_path"
require_relative "squishling/rotation"
require_relative "squishling/harness/option_types"
require_relative "squishling/harness/registry"
require_relative "squishling/harness/base"
require_relative "squishling/harness/escalation"
require_relative "squishling/harness/squishsum"
require_relative "squishling/harness/judged_squishsum"
require_relative "squishling/harness"
require_relative "squishling/result"
require_relative "squishling/schema"
require_relative "squishling/source"
require_relative "squishling/appendices"
require_relative "squishling/definition"
require_relative "squishling/llm_client"
require_relative "squishling/output_check"
require_relative "squishling/run/messages"
require_relative "squishling/run"
require_relative "squishling/invoker"
require_relative "squishling/judge"
require_relative "squishling/router"
require_relative "squishling/wrapper"
require_relative "squishling/class_methods"
require_relative "squishling/collisions"

# Include Squishling in a class to make it elastic: its squished methods either run their
# Ruby implementation or send their inputs through an LLM and return schema-validated results.
module Squishling
  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    def reset_config!
      @config = Configuration.new
    end

    # Forgets the registered harnesses (the built-ins stay), e.g. between specs. Kept apart from reset_config!
    # because harnesses are registered once at boot, and a suite that resets its config between examples
    # shouldn't lose them.
    def reset_harnesses!
      Harness::Registry.reset!
    end

    # Registers a custom harness under a name, usable anywhere a built-in type is (harness: :name, or
    # harness: { type: :name, option: value }, on a class, a method, a squish! call, or config.default_harness).
    # Pass a Harness::Base subclass, or a block that becomes the body of one (see Harness::Base). Registered
    # globally, so do it before the classes that use it load (an initializer). Raises ConfigurationError for a
    # name that is invalid or already taken, including the built-in :escalation, :squishsum, :judged_squishsum.
    def register_harness(name, klass = nil, &)
      Harness::Registry.register(name, klass, &)
    end

    # The names of the harnesses that can be declared: the built-ins, then those registered.
    def harnesses
      Harness.types
    end

    # Registers a custom adapter class (see Adapter::Base) under a name, usable as config.adapter = :name, or
    # config.adapter = { type: :name, option: value } for an adapter whose initialize takes options. To use an adapter
    # without registering it, assign an instance: config.adapter = MyAdapter.new. Raises ConfigurationError for a name
    # that is invalid or already taken, including the built-in :ruby_llm and :openai_compatible.
    def register_adapter(name, klass)
      Adapter::Registry.register(name, klass)
    end

    # The names of the adapters that can be configured: the built-ins, then those registered.
    def adapters
      Adapter::Registry.names
    end

    # Forgets the registered adapters (the built-ins stay), e.g. between specs.
    def reset_adapters!
      Adapter::Registry.reset!
    end

    def included(base)
      raise ConfigurationError, "Squishling can only be included in a class" unless base.is_a?(Class)

      # A redundant include in a subclass overrides nothing new: the superclass's own methods already won.
      Collisions.check!(base) unless base.superclass&.include?(Squishling)
      base.extend(ClassMethods)
      # `result` is a convenience alias for squishling_result; a class that already has a `result` keeps it.
      base.include(ResultAlias) unless base.method_defined?(:result) || base.private_method_defined?(:result)
      base.send(:squishling_install_wrapper)
    end
  end

  # Build the typed result for the squished method currently executing, validating it against
  # the output schema. Use this from the deterministic path so both paths return the same type.
  def squishling_result(attrs = nil, **kwargs)
    frame = Router.current_frame(self)
    raise Error, "#{self.class}#squishling_result called outside a squished method" unless frame

    frame.definition.build_result(attrs || kwargs, squished: false)
  end

  # Included separately, and only when the class has no `result` of its own, so `result` never shadows an
  # inherited one. A module (not an alias on the class) keeps it out of the class's own source.
  module ResultAlias
    def result(...)
      squishling_result(...)
    end
  end

  # Hand the squished method currently executing to the LLM, e.g. from a `rescue` when the Ruby path can't
  # handle this input. Returns the typed result (squished? true, or false when the declared fallback supplied
  # it); return it from the method. The overrides apply to this call only: append_to_purpose adds to (or,
  # with false, replaces) the declared sections, context is sent alongside the declared squish_context,
  # model/escalation (one or the other)/provider/purpose/harness replace the declared ones, and params merge
  # key by key over them.
  def squish!(append_to_purpose: nil, context: nil, purpose: nil, model: nil, escalation: nil, provider: nil,
    params: nil, harness: nil)
    Router.hand_off(self, { append_to_purpose:, context:, purpose:, model:, escalation:, provider:, params:,
                            harness: })
  end
end
