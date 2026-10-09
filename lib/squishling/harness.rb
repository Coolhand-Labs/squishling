# frozen_string_literal: true

module Squishling
  # How a squished call uses its escalation. Declared as a type, or a Hash with the type and its options:
  #   harness: :squishsum
  #   harness: { type: :judged_squishsum, judge: "claude-opus-5-5", compare: ->(a, b, **) { a.team == b.team } }
  # :escalation (the default) tries each attempt in order until an output passes. :squishsum asks the first
  # escalation step twice, concurrently, and accepts the output only when both samples agree. :judged_squishsum
  # hands disagreeing samples to a judge that picks one or rejects both.
  class Harness
    TYPES = %i[escalation squishsum judged_squishsum].freeze
    KEYS = %i[type judge judge_instructions compare].freeze

    # A judge is one step: a model name or a Hash with the escalation step keys (except order:), plus
    # type: (:chat, the default, or :judgment for a System One decision model through RubyLLM.judge) and,
    # for :judgment, min_confidence: (the probability the chosen candidate needs).
    JUDGE_TYPES = %i[chat judgment].freeze
    JUDGE_KEYS = %i[type min_confidence].freeze
    # Request keys RubyLLM's judgment protocols own (model and input are already reserved params).
    JUDGMENT_RESERVED_PARAMS = %i[state questions].freeze
    DEFAULT_MIN_CONFIDENCE = 0.8

    DEFAULT_JUDGE_INSTRUCTIONS = <<~TEXT.strip
      You are an impartial judge. Two independent attempts at the same operation returned different outputs,
      candidate "a" and candidate "b". Both already match the required output format, so judge only their
      content. You are given the operation's purpose and its input. Decide which candidate correctly and
      faithfully carries out the purpose for this input. If both do (for example, they differ only in
      wording), choose either one, preferring "a". Choose "neither" only when both are wrong or you can't tell
      whether either is correct. Never combine them or invent a third answer.
    TEXT

    attr_reader :type, :judge, :judge_instructions, :compare

    class << self
      def normalize(value, label)
        case value
        when Symbol, String then new(type: type_for(value, label))
        when Hash then from_hash(value, label)
        else
          raise ConfigurationError, "#{label}: harness must be one of #{TYPES.join(', ')} or a Hash with type:, " \
                                    "got #{value.inspect}"
        end
      end

      private

      def from_hash(hash, label)
        hash = hash.transform_keys(&:to_sym)
        unknown = hash.keys - KEYS
        raise ConfigurationError, "#{label}: unknown harness option(s) #{unknown.join(', ')}" if unknown.any?
        raise ConfigurationError, "#{label}: a harness Hash needs type:" unless hash.key?(:type)

        type = type_for(hash[:type], label)
        check_options!(type, hash, label)
        new(type:, judge: hash[:judge].nil? ? nil : normalize_judge(hash[:judge], label),
          judge_instructions: hash[:judge_instructions], compare: hash[:compare])
      end

      def type_for(value, label)
        type = value.to_s.to_sym if value.is_a?(Symbol) || value.is_a?(String)
        return type if TYPES.include?(type)

        raise ConfigurationError, "#{label}: unknown harness #{value.inspect} (use #{TYPES.join(', ')})"
      end

      def check_options!(type, hash, label)
        judge_options = %i[judge judge_instructions].select { |key| hash.key?(key) }
        if judge_options.any? && type != :judged_squishsum
          options = judge_options.map { |key| "#{key}:" }.join(", ")
          raise ConfigurationError, "#{label}: #{options} can only be used with the judged_squishsum harness"
        end
        if hash.key?(:compare) && type == :escalation
          raise ConfigurationError, "#{label}: compare: only applies to the squishsum harnesses"
        end
        unless hash[:compare].nil? || hash[:compare].is_a?(Proc)
          raise ConfigurationError, "#{label}: compare: must be a Proc, got #{hash[:compare].class}"
        end

        instructions = hash[:judge_instructions]
        return if instructions.nil? || instructions.is_a?(Proc)
        return if instructions.is_a?(String) && !instructions.strip.empty?

        raise ConfigurationError, "#{label}: judge_instructions: must be a non-blank String or a Proc"
      end

      # The judge as a normalized escalation step (see ModelPath), plus its type and min_confidence.
      def normalize_judge(judge, label)
        judge_label = "#{label} judge"
        return ModelPath.normalize_step(judge, judge_label).merge(type: :chat) unless judge.is_a?(Hash)

        judge = judge.transform_keys(&:to_sym)
        raise ConfigurationError, "#{judge_label}: a judge is one step, so it takes no order:" if judge.key?(:order)

        type = judge.fetch(:type, :chat)
        type = type.to_sym if type.is_a?(String)
        unless JUDGE_TYPES.include?(type)
          raise ConfigurationError,
            "#{judge_label}: type: must be one of #{JUDGE_TYPES.join(', ')}, got #{type.inspect}"
        end

        if type == :chat && judge.key?(:min_confidence)
          raise ConfigurationError, "#{judge_label}: min_confidence: only applies to type: :judgment judges"
        end

        step = ModelPath.normalize_step(judge.except(*JUDGE_KEYS), judge_label).merge(type:)
        return step unless type == :judgment

        reserved = (step[:params] || {}).keys & JUDGMENT_RESERVED_PARAMS
        if reserved.any?
          raise ConfigurationError, "#{judge_label}: #{reserved.join(', ')} can't be set through params " \
                                    "(controlled by Squishling/RubyLLM)"
        end

        step.merge(min_confidence: min_confidence(judge, judge_label))
      end

      def min_confidence(judge, label)
        value = judge.fetch(:min_confidence, DEFAULT_MIN_CONFIDENCE)
        return value.to_f if value.is_a?(Numeric) && value.between?(0, 1)

        raise ConfigurationError, "#{label}: min_confidence: must be a number from 0 to 1, got #{value.inspect}"
      end
    end

    def initialize(type:, judge: nil, judge_instructions: nil, compare: nil)
      @type = type
      @judge = judge
      @judge_instructions = judge_instructions
      @compare = compare
      freeze
    end

    DEFAULT = new(type: :escalation)

    def squishsum?
      type != :escalation
    end

    def judged?
      type == :judged_squishsum
    end
  end
end
