# frozen_string_literal: true

module Squishling
  # The models a squished call tries, in order. Declared either as one model (model: "claude-haiku-4-5", a
  # single attempt) or as an escalation: an Array of steps, each a model name or a Hash:
  #   escalation: [
  #     { model: "claude-haiku-4-5", attempts: 2 },
  #     "claude-sonnet-5-5",
  #     { model: "claude-opus-5-5", params: { thinking: { effort: :high } } }
  #   ]
  # attempts: (default 1) retries a step; order: (all steps or none, unique, lowest first) makes the order
  # explicit instead of positional. forward_rejected: false starts a step from the original input alone, without
  # the previous step's rejected output.
  module ModelPath
    # One attempt: the model, its provider, the fully resolved generation params, and whether the previous
    # step's rejected output is shown to it.
    Step = Data.define(:model, :provider, :params, :forward_rejected) do
      # The model for logs and messages (nil means RubyLLM's default model).
      def display_name
        model || "RubyLLM default model"
      end
    end

    STEP_KEYS = %i[model provider params attempts order forward_rejected].freeze

    module_function

    # A single model: model:/default_model. Returns a one-step path, or nil when not declared.
    def from_model(model, label)
      return nil if model.nil?

      if model.is_a?(Array) || model.is_a?(Hash)
        raise ConfigurationError, "#{label} takes one model; use escalation: [...] to try several in order"
      end

      [normalize_step(model, label)].freeze
    end

    # An escalation: escalation:/default_escalation. Returns the steps in order, or nil when not declared.
    def from_escalation(escalation, label)
      return nil if escalation.nil?
      unless escalation.is_a?(Array)
        raise ConfigurationError, "#{label} must be an Array of steps, got #{escalation.class}"
      end
      raise ConfigurationError, "#{label} can't be empty" if escalation.empty?

      ordered(escalation.map { |step| normalize_step(step, label) }, label).freeze
    end

    # model: and escalation: both describe what to try, so a level may declare only one of them.
    def declare(model, escalation, label)
      if !model.nil? && !escalation.nil?
        raise ConfigurationError, "#{label}: declare model: or escalation:, not both (put the model in the escalation)"
      end

      from_model(model, "#{label} model") || from_escalation(escalation, "#{label} escalation")
    end

    # One Step per attempt. The level's provider applies to steps that don't name their own, and each
    # step's params are merged over the level-resolved params.
    def steps(path, provider:, params:)
      path.flat_map do |step|
        attempt = Step.new(model: step[:model], provider: step[:provider] || provider,
          params: Params.resolve(params, step[:params]), forward_rejected: step[:forward_rejected])
        [attempt] * step[:attempts]
      end
    end

    def ordered(steps, label)
      numbered = steps.count { |step| step.key?(:order) }
      return steps.map { |step| step.except(:order) } if numbered.zero?

      if numbered < steps.size
        raise ConfigurationError, "#{label}: give every step an order: or none (#{numbered} of #{steps.size} have one)"
      end

      orders = steps.map { |step| step[:order] }
      duplicates = orders.tally.select { |_, count| count > 1 }.keys
      raise ConfigurationError, "#{label}: duplicate order: #{duplicates.join(', ')}" if duplicates.any?

      steps.sort_by { |step| step[:order] }.map { |step| step.except(:order) }
    end

    def normalize_step(step, label)
      case step
      when String, Symbol
        { model: model_name(step, label), provider: nil, params: nil, attempts: 1, forward_rejected: true }
      when Hash then normalize_hash(step, label)
      else
        raise ConfigurationError, "#{label}: each step must be a model name or a Hash with model:, got #{step.inspect}"
      end
    end

    def normalize_hash(step, label)
      step = step.transform_keys(&:to_sym)
      unknown = step.keys - STEP_KEYS
      raise ConfigurationError, "#{label}: unknown step option(s) #{unknown.join(', ')}" if unknown.any?
      unless step[:model].is_a?(String) || step[:model].is_a?(Symbol)
        raise ConfigurationError, "#{label}: a step needs a model: name, got #{step.inspect}"
      end

      model = model_name(step[:model], label)
      attempts = step.fetch(:attempts, 1)
      unless attempts.is_a?(Integer) && attempts.positive?
        raise ConfigurationError, "#{label} (#{model}): attempts: must be a positive Integer, got #{attempts.inspect}"
      end
      if step.key?(:order) && !step[:order].is_a?(Integer)
        raise ConfigurationError, "#{label} (#{model}): order: must be an Integer, got #{step[:order].inspect}"
      end

      forward_rejected = step.fetch(:forward_rejected, true)
      unless [true, false].include?(forward_rejected)
        raise ConfigurationError,
          "#{label} (#{model}): forward_rejected: must be true or false, got #{forward_rejected.inspect}"
      end

      params = step[:params] && Params.normalize(step[:params], "#{label} (#{model}) params")
      normalized = { model:, provider: step[:provider], params:, attempts:, forward_rejected: }
      step.key?(:order) ? normalized.merge(order: step[:order]) : normalized
    end

    def model_name(model, label)
      name = model.to_s
      raise ConfigurationError, "#{label}: model names can't be blank" if name.strip.empty?

      name
    end
  end
end
