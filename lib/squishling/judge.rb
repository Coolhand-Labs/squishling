# frozen_string_literal: true

module Squishling
  # Picks between a judged harness's two disagreeing samples (judged_squishsum or judged_ensemble), or rejects
  # both. The judge is the harness's judge: step, or else the escalation's next step after the ones the samples
  # ran on. A chat judge answers with a strict verdict schema; a :judgment judge (a System One decision model such
  # as Jev) answers one choice question through RubyLLM.judge, and its pick counts only at or above
  # min_confidence.
  class Judge
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

    def initialize(definition:, receiver:, client:, harness:, rest:, purpose:, payload:, escalate:, log_failure:)
      @definition = definition
      @receiver = receiver
      @client = client
      @harness = harness
      @purpose = purpose
      @payload = payload
      @escalate = escalate
      @log_failure = log_failure
      @steps = resolve_steps(rest)
    end

    # The judge's first attempt, for logs and DisagreementError#models.
    def step
      @steps.first
    end

    # [:a | :b, reason] for the chosen candidate, or [:neither, reason].
    def verdict(first, second)
      candidates = { a: Schema.jsonify(first.to_h), b: Schema.jsonify(second.to_h) }
      judgment? ? judgment(candidates) : chat(candidates)
    end

    private

    def judgment?
      @harness.judge&.fetch(:type) == :judgment
    end

    # A declared judge brings its own model and provider. A chat judge gets the method's generation params
    # under its own, like any escalation step; a judgment judge sends only its own params, as provider options.
    def resolve_steps(rest)
      if (judge = @harness.judge)
        params = judge[:type] == :judgment ? {} : @definition.params
        return ModelPath.steps([judge], provider: nil, params:)
      end

      if rest.empty?
        ordinal = @harness.ensemble? ? "third" : "second"
        raise ConfigurationError, "#{@definition.label}: the #{@harness.type} harness needs a judge: or a " \
                                  "#{ordinal} escalation step to judge with"
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
      [result[:verdict].to_sym, result[:reason]]
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
      minimum = @harness.judge[:min_confidence]
      shown = probability.round(3)
      return [choice, "chosen with probability #{shown}"] if %i[a b].include?(choice) && probability >= minimum
      return [:neither, "the judge chose neither (probability #{shown})"] if choice == :neither

      [:neither, "the judge chose #{choice} with probability #{shown}, below min_confidence #{minimum}"]
    end

    # A judgment always matches its questions, so only a failed request (LLMError) moves on to the next attempt.
    def judge_with_retries(input, questions)
      @steps.each.with_index(1) do |step, attempt|
        return @client.judge(input, questions:, step:)
      rescue LLMError => e
        raise if attempt == @steps.size

        @log_failure.call(:judge, attempt, @steps, e.message)
      end
    end

    def state(candidates)
      { input: @payload, output_schema: @definition.schema.llm_schema["schema"], candidates: }
    end

    def judge_instructions
      value = @harness.judge_instructions || Harness::DEFAULT_JUDGE_INSTRUCTIONS
      value = @receiver.instance_exec(&value) if value.is_a?(Proc)
      return value if value.is_a?(String) && !value.strip.empty?

      raise ConfigurationError, "#{@definition.label}: the judge_instructions proc must return a non-blank String"
    end
  end
end
