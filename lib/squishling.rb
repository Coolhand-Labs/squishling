# frozen_string_literal: true

require "json"
require "json_schemer"
require "ruby_llm"
require "schematist"

require_relative "squishling/version"
require_relative "squishling/errors"
require_relative "squishling/configuration"
require_relative "squishling/params"
require_relative "squishling/squawk"
require_relative "squishling/model_path"
require_relative "squishling/harness"
require_relative "squishling/result"
require_relative "squishling/schema"
require_relative "squishling/source"
require_relative "squishling/appendices"
require_relative "squishling/definition"
require_relative "squishling/llm_client"
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
