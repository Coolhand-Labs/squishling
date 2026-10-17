# frozen_string_literal: true

module Squishling
  # Picks between two disagreeing samples, or rejects both (see Run#judge). The judge is the given judge:
  # step, or else the escalation's next stage after the first. A chat judge answers with a strict verdict
  # schema; a :judgment judge (a System One decision model such as Jev) answers one choice question through
  # RubyLLM.judge, and its pick counts only at or above min_confidence.
  class Judge
    # The judge kinds: :chat (a chat model answering VERDICT_SCHEMA) and :judgment (a System One decision model
    # through RubyLLM.judge). A judge is an escalation step (see ModelPath) plus these keys: type: (default :chat)
    # and, for :judgment, min_confidence: (the probability the chosen candidate needs).
    TYPES = %i[chat judgment].freeze
    STEP_KEYS = %i[type min_confidence].freeze
    DEFAULT_MIN_CONFIDENCE = 0.8

    VERDICT_SCHEMA = {
      "type" => "object",
      "properties" => {
        "verdict" => { "type" => "string", "enum" => %w[a b neither] },
        "reason" => { "type" => "string" }
      },
      "required" => %w[verdict reason],
      "additionalProperties" => false
    }.freeze

    INPUT_NOTE = <<~NOTE
      The input is a JSON object. "input" is what the operation received ("arguments" and, when present,
      "context"); "output_schema" is the format both candidates follow; "candidates" holds "a" and "b".
      Respond only with JSON matching the required schema: your verdict ("a", "b", or "neither") and a short reason.
    NOTE

    CHOICES = {
      a: "Candidate a correctly carries out the purpose for this input (also when both do)",
      b: "Candidate b correctly carries out the purpose for this input",
      neither: "Neither candidate is clearly correct"
    }.freeze

    # What a judge decided: :a, :b, or :neither, with its reason. The detail is text Squishling wrote (nil for a
    # chat judge, whose reason is model-written) and is safe for error messages.
    Verdict = Data.define(:choice, :reason, :detail)

    # judge: is a normalized judge step (see Harness::JudgedSquishsum) or nil for the escalation's next stage,
    # instructions: a String, a Proc evaluated against the receiver, or nil for the default prompt.
    def initialize(definition:, receiver:, client:, judge:, instructions:, path:, purpose:, payload:, escalate:,
      log_failure:, guard:, harness_type:)
      @definition = definition
      @receiver = receiver
      @client = client
      @judge = judge
      @instructions = instructions
      check!
      @guard = guard
      @harness_type = harness_type
      @purpose = purpose
      @payload = payload
      @escalate = escalate
      @log_failure = log_failure
      @steps = resolve_steps(path)
    end

    # The judge's first attempt, for logs and DisagreementError#models.
    def step
      @steps.first
    end

    # The Verdict for the two candidates: :a or :b for the chosen one, or :neither.
    def verdict(first, second)
      @guard.call
      candidates = { a: Schema.jsonify(first.to_h), b: Schema.jsonify(second.to_h) }
      judgment? ? judgment(candidates) : chat(candidates)
    end

    private

    # What Run#judge was given. A harness declaration is checked earlier, with its own messages.
    def check!
      label = "#{@definition.label}: judge"
      if @judge
        type = @judge.fetch(:type)
        unless TYPES.include?(type)
          raise ConfigurationError, "#{label} type: must be one of #{TYPES.join(', ')}, got #{type.inspect}"
        end

        if type == :chat && @judge.key?(:min_confidence)
          raise ConfigurationError, "#{label} min_confidence: only applies to type: :judgment judges"
        end

        minimum = @judge.fetch(:min_confidence, DEFAULT_MIN_CONFIDENCE)
        unless minimum.is_a?(Numeric) && minimum.between?(0, 1)
          raise ConfigurationError, "#{label} min_confidence: must be a number from 0 to 1, got #{minimum.inspect}"
        end
      end
      return if @instructions.nil? || @instructions.is_a?(Proc) || non_blank_string?(@instructions)

      raise ConfigurationError, "#{label} instructions must be a non-blank String or a Proc"
    end

    def non_blank_string?(value)
      value.is_a?(String) && !value.strip.empty?
    end

    def judgment?
      @judge&.fetch(:type) == :judgment
    end

    # A declared judge brings its own model and provider. A chat judge gets the method's generation params
    # under its own, like any escalation step; a judgment judge sends only its own params, as provider options.
    def resolve_steps(path)
      if (judge = @judge)
        params = judge[:type] == :judgment ? {} : @definition.params
        return ModelPath.steps([judge], provider: nil, params:)
      end

      rest = path.drop_while { |step| step == path.first }
      if rest.empty?
        raise ConfigurationError, "#{@definition.label}: the #{@harness_type} harness needs a judge: or a second " \
                                  "escalation step to judge with"
      end

      rest.take_while { |step| step == rest.first }
    end

    def chat(candidates)
      prompt = Invoker::Prompt.new(
        instructions: "#{judge_instructions}\n\nThe operation's purpose:\n<purpose>\n#{@purpose}\n" \
                      "</purpose>\n\n#{INPUT_NOTE}",
        schema: Schema.for(VERDICT_SCHEMA), input: JSON.generate(state(candidates)), role: :judge
      )
      result = @escalate.call(@steps, prompt)
      Verdict.new(choice: result[:verdict].to_sym, reason: result[:reason], detail: nil)
    end

    def judgment(candidates)
      input = { purpose: @purpose, **state(candidates) }
      questions = { winner: { type: :choice, instructions: judge_instructions, options: CHOICES } }
      answer = judge_with_retries(input, questions)[:winner]
      unless answer.respond_to?(:choice) && answer.respond_to?(:probabilities)
        raise InvalidOutputError.new(errors: ["the judgment didn't answer the winner question"], source: "Judge")
      end

      interpret(answer.choice.to_s.to_sym, answer.probabilities)
    end

    # The threshold is checked on the exact probability; it's rounded only for the reason text.
    def interpret(choice, probabilities)
      probability = probabilities.to_h.find { |key, _| key.to_s == choice.to_s }&.last.to_f
      minimum = @judge.fetch(:min_confidence, DEFAULT_MIN_CONFIDENCE)
      shown = probability.round(3)
      picked = %i[a b].include?(choice)
      if picked && probability >= minimum
        text = "chosen with probability #{shown}"
        return Verdict.new(choice:, reason: text, detail: text)
      end

      text =
        if choice == :neither then "the judge chose neither (probability #{shown})"
        elsif picked then "the judge chose #{choice} with probability #{shown}, below min_confidence #{minimum}"
        else "the judge returned an unrecognized choice (probability #{shown})"
        end
      Verdict.new(choice: :neither, reason: text, detail: text)
    end

    # A judgment always matches its questions, so only a failed request (LLMError) moves on to the next attempt.
    def judge_with_retries(input, questions)
      @steps.each.with_index(1) do |step, attempt|
        return @client.judge(input, questions:, step:, attempt:, attempts: @steps.size)
      rescue LLMError => e
        raise if attempt == @steps.size

        @log_failure.call(:judge, attempt, @steps, e.message)
      end
    end

    def state(candidates)
      { input: @payload, output_schema: @definition.schema.llm_schema["schema"], candidates: }
    end

    def judge_instructions
      value = @instructions || Harness::DEFAULT_JUDGE_INSTRUCTIONS
      value = @receiver.instance_exec(&value) if value.is_a?(Proc)
      return value if value.is_a?(String) && !value.strip.empty?

      raise ConfigurationError, "#{@definition.label}: the judge_instructions proc must return a non-blank String"
    end
  end
end
