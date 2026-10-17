# frozen_string_literal: true

module Squishling
  # The around-style hook for tools that must see an LLM request while it is made (a tracing span, a Coolhand
  # declared workload), which squawk's after-the-fact report can't do. An evaluator is any object responding to
  # around(call), which yields to make the request and returns the block's value. See docs/evaluators.md.
  #
  # Evaluators get call metadata only (Call), never the model's output or the method's inputs.
  module Evaluator
    # What an evaluator is told about one provider request. role is nil for an escalation attempt, :sample (with
    # sample "a", "b", ...) or :judge, like squawk's metadata. attempt and attempts count the (expanded)
    # escalation path the request belongs to. request is :chat, or :judgment for a System One judge.
    Call = Data.define(:label, :purpose, :harness, :role, :sample, :attempt, :attempts, :model, :provider,
      :request)

    BUILT_IN = %i[coolhand].freeze

    module_function

    # The evaluator itself, nil (auto-detect), or false (none). A built-in's name (:coolhand) or anything that
    # responds to around is accepted, checked here so a mistake fails at setup, not inside the first request.
    def validate(evaluator, where)
      return evaluator if evaluator.nil? || evaluator == false

      if evaluator.is_a?(Symbol)
        return evaluator if BUILT_IN.include?(evaluator)

        raise ConfigurationError, "#{where} evaluator must be one of #{BUILT_IN.map(&:inspect).join(', ')}, " \
                                  "an object that responds to around, or false, got #{evaluator.inspect}"
      end
      return evaluator if evaluator.respond_to?(:around)

      raise ConfigurationError, "#{where} evaluator must respond to around(call) { ... } (or be false), " \
                                "got #{evaluator.inspect}"
    end

    # The evaluator that wraps a request: the configured one, the Coolhand evaluator when nothing is configured and
    # Coolhand is loaded and set up, or nil.
    def resolve(configured)
      case configured
      when false then nil
      when nil then Evaluators::Coolhand.new if Evaluators::Coolhand.available?
      when Symbol then Evaluators::Coolhand.new
      else configured
      end
    end

    # Runs the request inside the resolved evaluator, if there is one. The block runs on the calling thread, so
    # for samples it is the worker thread that makes the request. An evaluator that never yields would make the
    # request vanish, so that's a setup mistake.
    def around(call)
      evaluator = resolve(Squishling.config.evaluator)
      return yield unless evaluator

      yielded = false
      value = evaluator.around(call) do
        yielded = true
        yield
      end
      return value if yielded

      raise ConfigurationError,
        "#{call.label}: the #{evaluator.class} evaluator's around must yield to make the request"
    end
  end
end
