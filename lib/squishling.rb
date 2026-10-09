# frozen_string_literal: true

require "json"
require "json_schemer"
require "ruby_llm"
require "schematist"

require_relative "squishling/version"
require_relative "squishling/errors"
require_relative "squishling/configuration"
require_relative "squishling/params"
require_relative "squishling/model_path"
require_relative "squishling/result"
require_relative "squishling/schema"
require_relative "squishling/source"
require_relative "squishling/appendices"
require_relative "squishling/definition"
require_relative "squishling/invoker"
require_relative "squishling/router"
require_relative "squishling/wrapper"
require_relative "squishling/class_methods"

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

      base.extend(ClassMethods)
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

  alias_method :result, :squishling_result

  # Hand the squished method currently executing to the LLM, e.g. from a `rescue` when the Ruby path can't
  # handle this input. Returns the typed result (squished? true, or false when the declared fallback supplied
  # it); return it from the method. The overrides apply to this call only: append_instructions adds to (or,
  # with false, replaces) the declared sections, context is sent alongside the declared squish_context,
  # model/escalation (one or the other)/provider/instructions replace the declared ones, and params merge key
  # by key over them.
  def squish!(append_instructions: nil, context: nil, instructions: nil, model: nil, escalation: nil, provider: nil,
    params: nil)
    Router.hand_off(self, { append_instructions:, context:, instructions:, model:, escalation:, provider:, params: })
  end
end
