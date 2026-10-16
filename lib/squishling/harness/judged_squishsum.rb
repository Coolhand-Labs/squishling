# frozen_string_literal: true

module Squishling
  class Harness
    # Like Squishling::Harness::Squishsum, but samples that disagree go to a judge, which picks one or rejects both.
    # A judge is one step: a model name or a Hash with the escalation step keys (except order:), plus
    # type: (:chat, the default, or :judgment for a System One decision model through RubyLLM.judge) and,
    # for :judgment, min_confidence: (the probability the chosen candidate needs).
    class JudgedSquishsum < Base
      # Request keys RubyLLM's judgment protocols own (model and input are already reserved params).
      JUDGMENT_RESERVED_PARAMS = %i[state questions].freeze
      private_constant :JUDGMENT_RESERVED_PARAMS

      class << self
        # A judge as a normalized escalation step (see ModelPath), plus its type and min_confidence. label is the
        # declaration site and name the option it came from. Internal.
        def normalize_judge(judge, label, name = :judge)
          judge_label = "#{label} #{name}"
          return ModelPath.normalize_step(judge, judge_label).merge(type: :chat) unless judge.is_a?(Hash)

          judge = judge.transform_keys(&:to_sym)
          raise ConfigurationError, "#{judge_label}: a judge is one step, so it takes no order:" if judge.key?(:order)

          type = judge.fetch(:type, :chat)
          type = type.to_sym if type.is_a?(String)
          unless Judge::TYPES.include?(type)
            raise ConfigurationError,
              "#{judge_label}: type: must be one of #{Judge::TYPES.join(', ')}, got #{type.inspect}"
          end

          if type == :chat && judge.key?(:min_confidence)
            raise ConfigurationError, "#{judge_label}: min_confidence: only applies to type: :judgment judges"
          end

          step = ModelPath.normalize_step(judge.except(*Judge::STEP_KEYS), judge_label).merge(type:)
          return step unless type == :judgment

          reserved = (step[:params] || {}).keys & JUDGMENT_RESERVED_PARAMS
          if reserved.any?
            raise ConfigurationError, "#{judge_label}: #{reserved.join(', ')} can't be set through params " \
                                      "(controlled by Squishling/RubyLLM)"
          end

          step.merge(min_confidence: min_confidence(judge, judge_label))
        end

        # The judge's prompt: a non-blank String, or a Proc evaluated against the instance. Internal.
        def normalize_instructions(value, label, name = :judge_instructions)
          return value if value.is_a?(Proc)
          return value.dup.freeze if value.is_a?(String) && !value.strip.empty?

          raise ConfigurationError, "#{label}: #{name}: must be a non-blank String or a Proc"
        end

        private

        def min_confidence(judge, label)
          value = judge.fetch(:min_confidence, Judge::DEFAULT_MIN_CONFIDENCE)
          return value.to_f if value.is_a?(Numeric) && value.between?(0, 1)

          raise ConfigurationError, "#{label}: min_confidence: must be a number from 0 to 1, got #{value.inspect}"
        end
      end

      option :compare, :proc
      option :judge, ->(value, label, name) { normalize_judge(value, label, name) }
      option :judge_instructions, ->(value, label, name) { normalize_instructions(value, label, name) }

      def call(run, compare: nil, judge: nil, judge_instructions: nil)
        stage = run.stages.first
        # The judge is resolved before any sample is requested, so a missing one fails before costing anything.
        judge = run.judge(judge:, instructions: judge_instructions)
        first, second = run.samples([stage, stage])
        return first if run.agree?(first, second, compare)

        run.log("samples disagreed, asking the judge (#{judge.step.display_name})")
        verdict = judge.verdict(first, second)
        return { a: first, b: second }.fetch(verdict.choice) unless verdict.choice == :neither

        models = [stage.first.model] * 2
        raise DisagreementError.new(candidates: [first, second], verdict: :neither, reason: verdict.reason,
          detail: verdict.detail, models: models + [judge.step.model])
      end
    end

    Registry.register_built_in(:judged_squishsum, JudgedSquishsum)
  end
end
