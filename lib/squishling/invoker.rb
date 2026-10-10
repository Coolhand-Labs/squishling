# frozen_string_literal: true

module Squishling
  # The elastic path: sends a squished method's inputs through RubyLLM with structured output.
  class Invoker
    INPUT_NOTE = <<~NOTE
      The input is a JSON object. "arguments" holds the values passed to this operation; "context", when
      present, holds additional state about the caller. Respond only with JSON matching the required schema.
    NOTE

    # The most of a rejected output that is forwarded to the next escalation step.
    MAX_FORWARDED_CHARS = 4_000

    # One escalation's request: the system prompt, the output Schema, and the first user message. The judge's
    # role (:judge) skips squish_validate and names the judge in errors and logs.
    Prompt = Data.define(:instructions, :schema, :input, :role)

    # One of a sampling harness's two samples, between rounds: the steps it may attempt, in order.
    Sample = Struct.new(:name, :steps, :chat, :rejected, :result)

    def initialize(definition, receiver, inputs)
      @definition = definition
      @receiver = receiver
      @inputs = inputs
      @client = LLMClient.new(definition.label)
      @output_check = OutputCheck.new(definition, receiver, inputs)
    end

    # Runs the harness (Definition#harness) over the escalation (Definition#escalation_path).
    def call
      purpose = @definition.purpose(@receiver)
      schema = @definition.schema
      raise ConfigurationError, "#{@definition.label} has no purpose" if purpose.nil? || purpose.empty?
      raise ConfigurationError, "#{@definition.label} has no output_schema" unless schema

      harness = @definition.harness
      path = @definition.escalation_path
      body = payload
      prompt = Prompt.new(instructions: "#{purpose}\n\n#{INPUT_NOTE}", schema:,
        input: JSON.generate(body), role: nil)
      return escalate(path, prompt) unless harness.squishsum?

      # The sample steps and the judge are resolved before any sample is requested, so a missing one fails
      # before costing anything.
      sample_steps, rest = sampling_plan(path, harness)
      judge = harness.judged? && Judge.new(definition: @definition, receiver: @receiver, client: @client, harness:,
        rest:, purpose:, payload: body, escalate: method(:escalate),
        log_failure: method(:log_failure))
      sample(sample_steps, prompt, harness, judge)
    end

    private

    # Splits the escalation into runs of consecutive identical steps (a step's attempts). A squishsum samples
    # the first run twice; an ensemble samples the first run, then the second. Returns each sample's steps and
    # the rest of the escalation, which is where a judge looks for its default step.
    def sampling_plan(path, harness)
      runs = path.chunk_while { |step, following| step == following }.to_a
      if harness.ensemble? && runs.size < 2
        raise ConfigurationError, "#{@definition.label}: the #{harness.type} harness needs a second escalation " \
                                  "step to sample (adjacent identical steps count as one step's attempts)"
      end

      return [runs.first(2), runs.drop(2).flatten(1)] if harness.ensemble?

      [[runs.first, runs.first], runs.drop(1).flatten(1)]
    end

    # Makes each attempt of the path until an output passes the schema and the squish_validate check.
    # Consecutive attempts on the same step continue the same conversation, so the model sees what it got wrong;
    # a new step starts a fresh chat told about the last rejected output (unless the step sets
    # forward_rejected: false).
    def escalate(path, prompt)
      chat = nil
      rejected = nil # [raw content, errors] of the last invalid output
      models = []

      path.each.with_index(1) do |step, attempt|
        models << step.model
        last = attempt == path.size
        if chat && step == path[attempt - 2]
          message = retry_message(rejected.last)
        else
          chat = start_chat(step, prompt)
          message = rejected && step.forward_rejected ? escalation_message(prompt.input, *rejected) : prompt.input
        end

        begin
          response = @client.ask(chat, message, step)
        rescue LLMError => e
          squawk(prompt, path, attempt, nil, e)
          raise if last

          # The failed request may be half-recorded in this chat, so the next attempt starts a fresh one.
          chat = nil
          log_failure(prompt.role, attempt, path, e.message)
          next
        end

        result, errors = @output_check.call(response.content, prompt)
        if errors.empty?
          squawk(prompt, path, attempt, response, nil)
          return result
        end

        error = InvalidOutputError.new(errors:, raw: response.content, attempts: attempt, models: models.dup,
          source: source(prompt.role))
        squawk(prompt, path, attempt, response, error)
        raise error if last

        rejected = [response.content, errors]
        log_failure(prompt.role, attempt, path, errors.join("; "))
      end
    end

    # Two samples, each on its own steps and retried per their attempts the same way escalate retries.
    # Each round sends the pending samples' requests concurrently; everything else runs on this thread.
    def sample(sample_steps, prompt, harness, judge)
      samples = %w[a b].zip(sample_steps).map { |name, steps| Sample.new(name, steps) }

      1.upto(sample_steps.map(&:size).max) do |attempt|
        pending = samples.reject(&:result)
        break if pending.empty?

        jobs = pending.map do |sample|
          step = sample.steps[attempt - 1]
          message = sample_message(sample, step, prompt)
          -> { @client.ask(sample.chat, message, step) }
        end
        outcomes = LLMClient.concurrently(jobs)
        # A setup mistake (or anything that isn't a failed request) ends the call, whichever sample hit it.
        fatal = outcomes.map(&:last).find { |error| error && !error.is_a?(LLMError) }
        raise fatal if fatal

        pending.zip(outcomes).each { |sample, outcome| record(sample, outcome, prompt, attempt) }
      end

      settle(samples, harness, judge)
    end

    # The next message for a sample: a retry in its chat after invalid output, otherwise a fresh chat.
    def sample_message(sample, step, prompt)
      return retry_message(sample.rejected.last) if sample.chat

      sample.chat = start_chat(step, prompt)
      sample.rejected && step.forward_rejected ? escalation_message(prompt.input, *sample.rejected) : prompt.input
    end

    def record(sample, (response, error), prompt, attempt)
      steps = sample.steps
      last = attempt == steps.size
      role = "sample #{sample.name}"
      if error
        squawk(prompt, steps, attempt, nil, error)
        raise error if last

        sample.chat = nil
        return log_failure(role, attempt, steps, error.message)
      end

      result, errors = @output_check.call(response.content, prompt)
      if errors.empty?
        squawk(prompt, steps, attempt, response, nil)
        return sample.result = result
      end

      models = steps.first(attempt).map(&:model)
      invalid = InvalidOutputError.new(errors:, raw: response.content, attempts: attempt, models:)
      squawk(prompt, steps, attempt, response, invalid)
      raise invalid if last

      sample.rejected = [response.content, errors]
      log_failure(role, attempt, steps, errors.join("; "))
    end

    # Agreeing samples are accepted; otherwise the judge, if any, picks one or the call fails.
    def settle(samples, harness, judge)
      first, second = samples.map(&:result)
      return first if agree?(first, second, harness.compare)

      models = samples.map { |sample| sample.steps.first.model }
      unless judge
        log_warning("samples disagreed")
        raise DisagreementError.new(candidates: [first, second], models:)
      end

      log_warning("samples disagreed, asking the judge (#{judge.step.display_name})")
      choice, reason, detail = judge.verdict(first, second)
      return { a: first, b: second }.fetch(choice) unless choice == :neither

      raise DisagreementError.new(candidates: [first, second], verdict: :neither, reason:, detail:,
        models: models + [judge.step.model])
    end

    # compare: is the developer's own code, so its exceptions propagate unwrapped.
    def agree?(first, second, compare)
      return Schema.jsonify(first.to_h) == Schema.jsonify(second.to_h) unless compare

      @receiver.instance_exec(first, second, **@inputs, &compare) ? true : false
    end

    def start_chat(step, prompt)
      @client.chat(step, instructions: prompt.instructions, schema: prompt.schema.llm_schema)
    end

    # Only the arguments, the declared squish_context names, and a squish! call's context leave the process.
    def payload
      body = { arguments: Schema.jsonify(describe(@inputs)) }
      context = @definition.context_names.to_h { |name| [name, context_value(name)] }.merge(@definition.call_context)
      body[:context] = Schema.jsonify(describe(context)) if context.any?
      body
    end

    # Exceptions are sent as their class and message. Plain JSON would send only the message, and with
    # json/add/exception loaded it would also send the backtrace, which exposes file paths.
    def describe(value)
      case value
      when Exception then { class: exception_class_name(value.class), message: value.message }
      when Hash then value.transform_values { |item| describe(item) }
      when Array then value.map { |item| describe(item) }
      else value
      end
    end

    # An anonymous error class (Class.new(StandardError)) is named after its closest named ancestor.
    def exception_class_name(klass)
      klass = klass.superclass until klass.name
      klass.name
    end

    def context_value(name)
      return @receiver.send(name) if @receiver.respond_to?(name, true)

      @receiver.instance_variable_get(:"@#{name}")
    end

    def retry_message(errors)
      "Your previous response was rejected:\n- #{errors.join("\n- ")}\nRespond again with corrected JSON only."
    end

    # The first message to a fresh chat after an earlier model's output was rejected. The rejected output is
    # model-generated and may cross providers, so it is capped at MAX_FORWARDED_CHARS.
    def escalation_message(input, raw, errors)
      previous = raw.is_a?(String) ? raw : JSON.generate(raw)
      previous = "(an empty response)" if previous.strip.empty? || raw.nil?
      if previous.length > MAX_FORWARDED_CHARS
        omitted = previous.length - MAX_FORWARDED_CHARS
        previous = "#{previous[0, MAX_FORWARDED_CHARS]}... [truncated, #{omitted} more characters]"
      end
      "#{input}\n\nA previous attempt at this request returned:\n#{previous}\n" \
        "It was rejected:\n- #{errors.join("\n- ")}\nRespond with corrected JSON only."
    end

    # Runs the observability hook, if any, with this attempt's raw output (nil when the call itself failed),
    # the error that ended it (nil when it was accepted), and what was asked.
    def squawk(prompt, path, attempt, response, error)
      hook = @definition.squawk
      return unless hook

      step = path[attempt - 1]
      metadata = {
        label: @definition.label, attempt:, attempts: path.size, final: attempt == path.size,
        model: response&.model || step.model, provider: step.provider, params: step.params, input: prompt.input,
        usage: response&.tokens&.to_h
      }
      Squawk.call(hook, output: response&.content, metadata:, error:)
    end

    def source(role)
      role == :judge ? "Judge" : "LLM"
    end

    def log_failure(role, attempt, path, reason)
      step = path[attempt - 1]
      next_step = path[attempt]
      action = next_step == step ? "retrying" : "escalating to #{next_step.display_name}"
      who = role ? "#{role} attempt" : "attempt"
      log_warning("#{who} #{attempt} of #{path.size} (#{step.display_name}) failed, #{action}: #{reason}")
    end

    def log_warning(message)
      Squishling.config.logger&.warn("[Squishling] #{@definition.label} #{message}")
    end
  end
end
