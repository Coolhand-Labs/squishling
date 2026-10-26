# frozen_string_literal: true

module Squishling
  # The models a squished call tries, in order. Declared either as one model (model: "claude-haiku-4-5", a
  # single attempt) or as an escalation: an Array of steps, each a model name or a Hash:
  #   escalation: [
  #     { model: "claude-haiku-4-5", attempts: 2 },
  #     "claude-sonnet-5-5",
  #     { model: "claude-opus-5-5", params: { thinking: { effort: :high } } }
  #   ]
  # attempts: (default 1) retries a step; priority: (all steps or none, lowest first) makes the order explicit
  # instead of positional. Steps sharing a priority are one tier: each call rotates which of them goes first
  # (see Rotation), and the others follow before the next tier, unless a step in the tier sets rotate: false.
  # order: is the deprecated name of priority:. forward_rejected: false starts a step from the original input
  # alone, without the previous step's rejected output. include_when: (a Proc, called like squish_when with the
  # method's inputs as keywords, on the instance) drops the step from any call where it is falsy.
  # retry_temperature: (a Numeric) is the temperature for the step's same-chat retries after the first attempt.
  module ModelPath
    # One attempt: the model, its provider, the fully resolved generation params, whether the previous
    # step's rejected output is shown to it, and the temperature its retries in the same chat use, if any.
    Step = Data.define(:model, :provider, :params, :forward_rejected, :retry_temperature) do
      def initialize(model:, provider:, params:, forward_rejected:, retry_temperature: nil)
        super
      end

      # The params for a request: on a retry in the same chat (reask), the step's retry_temperature replaces the
      # temperature, if it sets one.
      def request_params(reask)
        reask && retry_temperature ? Params.resolve(params, temperature: retry_temperature) : params
      end

      # The model for logs and messages (nil means the adapter's default model).
      def display_name
        model || "the adapter's default model"
      end
    end

    STEP_KEYS = %i[model provider params attempts priority order rotate forward_rejected include_when
                   retry_temperature].freeze

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
    # step's params are merged over the level-resolved params. turn is this call's place in the method's rotation
    # (see Rotation): each tier of tied priorities starts turn steps further along.
    def steps(path, provider:, params:, turn: 0)
      rotated(path, turn).flat_map do |step|
        attempt = Step.new(model: step[:model], provider: step[:provider] || provider,
          params: Params.resolve(params, step[:params]), forward_rejected: step[:forward_rejected],
          retry_temperature: step[:retry_temperature])
        [attempt] * step[:attempts]
      end
    end

    # The steps this call may use: those without an include_when:, and those whose include_when: is truthy for the
    # call's inputs (evaluated against the receiver, like squish_when). Priority order is kept.
    def eligible(path, receiver, inputs, label)
      kept = path.select do |step|
        gate = step[:include_when]
        gate.nil? || receiver.instance_exec(**inputs, &gate)
      end
      raise ConfigurationError, "#{label}: include_when: excluded every escalation step" if kept.empty?

      kept
    end

    # Whether any tier of the path has several models to rotate between.
    def rotating?(path)
      tiers(path).any? { |tier| rotates?(tier) }
    end

    # Steps sorted by priority, lowest first, ties kept in the order declared.
    def ordered(steps, label)
      numbered = steps.count { |step| step.key?(:priority) }
      return steps if numbered.zero?

      if numbered < steps.size
        raise ConfigurationError,
          "#{label}: give every step a priority: or none (#{numbered} of #{steps.size} have one)"
      end

      steps.each_with_index.sort_by { |step, index| [step[:priority], index] }.map(&:first)
    end

    # Runs of steps with the same priority. A step without one is a tier of its own.
    def tiers(path)
      path.slice_when { |before, after| before[:priority].nil? || before[:priority] != after[:priority] }
    end

    def rotates?(tier)
      tier.size > 1 && tier.none? { |step| step[:rotate] == false }
    end

    def rotated(path, turn)
      tiers(path).flat_map { |tier| rotates?(tier) ? tier.rotate(turn % tier.size) : tier }
    end

    # extras: names more keys a step Hash may carry for its caller (a judge's type:, say). They are kept as given,
    # for the caller to check.
    def normalize_step(step, label, extras: [])
      case step
      when String, Symbol
        { model: model_name(step, label), provider: nil, params: nil, attempts: 1, forward_rejected: true }
      when Hash then normalize_hash(step, label, extras)
      else
        raise ConfigurationError, "#{label}: each step must be a model name or a Hash with model:, got #{step.inspect}"
      end
    end

    def normalize_hash(step, label, extras)
      step = step.transform_keys(&:to_sym)
      unknown = step.keys - STEP_KEYS - extras
      raise ConfigurationError, "#{label}: unknown step option(s) #{unknown.join(', ')}" if unknown.any?
      unless step[:model].is_a?(String) || step[:model].is_a?(Symbol)
        raise ConfigurationError, "#{label}: a step needs a model: name, got #{step.inspect}"
      end

      model = model_name(step[:model], label)
      attempts = step.fetch(:attempts, 1)
      unless attempts.is_a?(Integer) && attempts.positive?
        raise ConfigurationError, "#{label} (#{model}): attempts: must be a positive Integer, got #{attempts.inspect}"
      end

      step = priority_alias(step, label, model)
      if step.key?(:priority) && !step[:priority].is_a?(Integer)
        raise ConfigurationError, "#{label} (#{model}): priority: must be an Integer, got #{step[:priority].inspect}"
      end
      if step.key?(:rotate) && ![true, false].include?(step[:rotate])
        raise ConfigurationError, "#{label} (#{model}): rotate: must be true or false, got #{step[:rotate].inspect}"
      end

      check_include_when!(step, label, model)
      check_retry_temperature!(step, label, model)
      forward_rejected = step.fetch(:forward_rejected, true)
      unless [true, false].include?(forward_rejected)
        raise ConfigurationError,
          "#{label} (#{model}): forward_rejected: must be true or false, got #{forward_rejected.inspect}"
      end

      params = step[:params] && Params.normalize(step[:params], "#{label} (#{model}) params")
      normalized = { model:, provider: step[:provider], params:, attempts:, forward_rejected: }
      normalized.merge(step.slice(:priority, :rotate, :include_when, :retry_temperature, *extras))
    end

    def check_include_when!(step, label, model)
      return if !step.key?(:include_when) || step[:include_when].is_a?(Proc)

      raise ConfigurationError,
        "#{label} (#{model}): include_when: must be a Proc, got #{step[:include_when].inspect}"
    end

    def valid_temperature?(temperature)
      temperature.is_a?(Numeric) && temperature.real? && temperature.finite? && !temperature.negative?
    end

    def check_retry_temperature!(step, label, model)
      temperature = step[:retry_temperature]
      return if !step.key?(:retry_temperature) || valid_temperature?(temperature)

      raise ConfigurationError,
        "#{label} (#{model}): retry_temperature: must be a finite Numeric of 0 or more, got #{temperature.inspect}"
    end

    # A step used on its own (a judge, a harness's step) can't take part in a tier or be left out of a call, so it
    # takes no priority:, rotate:, or include_when:. who names it for the message.
    def single_step!(step, who)
      return unless step.key?(:priority) || step.key?(:rotate) || step.key?(:include_when)

      raise ConfigurationError, "#{who} takes no priority:, rotate:, or include_when:"
    end

    # order: is the deprecated name of priority:.
    def priority_alias(step, label, model)
      return step unless step.key?(:order)
      raise ConfigurationError, "#{label} (#{model}): give priority: or order:, not both" if step.key?(:priority)

      warn "[Squishling] #{label} (#{model}): order: is deprecated, use priority:"
      step.except(:order).merge(priority: step[:order])
    end

    def model_name(model, label)
      name = model.to_s
      raise ConfigurationError, "#{label}: model names can't be blank" if name.strip.empty?

      name
    end
  end
end
