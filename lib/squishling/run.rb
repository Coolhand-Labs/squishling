# frozen_string_literal: true

module Squishling
  # One squished call, as a harness sees it (see Harness::Base): the primitives that ask the model for outputs,
  # and everything they do for free: model, provider, and params resolution, schema and squish_validate checks,
  # retries in the same chat, escalation, squawk reports, and Squishling's own errors when attempts run out.
  # Each returns typed results, the same type as the deterministic path.
  #
  # A stage is the attempts of one escalation step (a model with its attempts:), as an Array of
  # ModelPath::Step. Primitives take stages, or anything that declares one (a model name or a step Hash).
  #
  # Primitives must be called from the thread that runs the harness. Only the provider requests inside them run
  # on other threads; parsing, validation, and every callback (squish_validate, compare:, procs) stay on this one.
  class Run
    include Messages
    include Repeats
    include Rejections

    private_constant :Messages, :Repeats

    # One of #samples' outputs, between rounds.
    Sample = Struct.new(:name, :stage, :chat, :rejected, :result, :reask)

    SAMPLE_NAMES = ("a".."z").to_a.freeze
    private_constant :Sample, :SAMPLE_NAMES

    attr_reader :receiver, :inputs, :steps

    def initialize(definition:, receiver:, inputs:, prompt:, payload:, purpose:, harness:)
      @definition = definition
      @receiver = receiver
      @inputs = inputs
      @prompt = prompt
      @payload = payload
      @purpose = purpose
      @harness = harness
      @steps = definition.escalation_path(receiver, inputs).freeze
      @client = LLMClient.new(definition.label, purpose:, harness: harness.type, handed_off: definition.handed_off)
      @output_check = OutputCheck.new(definition, receiver, inputs)
      @owner = Thread.current
      @produced = {}.compare_by_identity
    end

    # Whether value is a result one of this run's primitives returned (not one built by hand).
    def produced?(value)
      @produced.key?(value)
    end

    # The squished method, as "Class#method".
    def label
      @definition.label
    end

    # The escalation's steps grouped into stages: runs of identical consecutive steps, the attempts of one model.
    def stages
      @stages ||= steps.slice_when { |before, after| before != after }.map(&:freeze).freeze
    end

    # A stage from a model name or a step Hash (model:, provider:, params:, attempts:, forward_rejected:,
    # retry_temperature:), the way a judge step is resolved: it keeps its own provider, and its params merge over
    # the method's.
    # A stage (an Array of steps) is returned as is, and a single step is a stage of one attempt.
    def stage(declaration)
      return checked_stage([declaration]) if declaration.is_a?(ModelPath::Step)

      if declaration.is_a?(Array)
        return checked_stage(declaration) if declaration.any? && declaration.all?(ModelPath::Step)

        raise ConfigurationError, "#{label}: a stage is the steps of one model, got #{declaration.inspect}"
      end

      step = Harness::OptionTypes.check(:step, declaration, label, :"harness step")
      ModelPath.steps([step], provider: nil, params: @definition.params).freeze
    end

    # Makes each attempt of the stages in order (the escalation's steps when none are given) until an output
    # passes the schema and squish_validate. Consecutive attempts on the same step continue the same chat, so the
    # model sees what it got wrong; a new step starts a fresh chat told about the last rejected output (unless
    # the step sets forward_rejected: false). A retry that repeats the rejected output it was just told about gives
    # up on the rest of its step's attempts. Raises InvalidOutputError, or LLMError, when the last attempt fails.
    def escalate(*stages)
      owner!
      path = stages.empty? ? steps : stages.flat_map { |declared| stage(declared) }
      escalate_with(path, @prompt)
    end

    # One sample per stage (the attempts of one model), each asked on its own chat, each retried per its stage's
    # attempts like #escalate, with the requests of every round sent concurrently. Returns the outputs in order.
    # Samples are named "a", "b", ... in squawk reports.
    def samples(stages)
      owner!
      raise ConfigurationError, "#{label}: samples takes an Array of stages" unless stages.is_a?(Array)

      stages = stages.map { |declared| stage(declared) }
      raise ConfigurationError, "#{label}: samples needs at least one stage" if stages.empty?
      if stages.size > SAMPLE_NAMES.size
        raise ConfigurationError, "#{label}: samples takes at most #{SAMPLE_NAMES.size} stages"
      end

      if (mixed = stages.find { |sample_stage| sample_stage.uniq.size > 1 })
        raise ConfigurationError, "#{label}: a sample is asked on one model, so its stage can't mix steps " \
                                  "(got #{mixed.map(&:display_name).join(', ')})"
      end

      samples = stages.zip(SAMPLE_NAMES).map { |sample_stage, name| Sample.new(name, sample_stage) }
      (1..stages.map(&:size).max).each do |attempt|
        pending = samples.reject(&:result)
        break if pending.empty?

        round(pending, attempt)
      end
      samples.map(&:result)
    end

    # A judge that picks between two outputs (see Judge#verdict, which returns a Judge::Verdict), or rejects
    # both. judge: is a model name or a Hash with model:, provider:, params:, and attempts: (as an escalation
    # step, without priority:), plus type: :chat (default) or :judgment and, for :judgment, min_confidence:.
    # Without one, the judge is the escalation's next stage after the first. instructions: is a String, or a
    # Proc evaluated against the receiver, replacing Harness::DEFAULT_JUDGE_INSTRUCTIONS. The judge is resolved
    # here, so a missing one raises ConfigurationError before any request is made.
    def judge(judge: nil, instructions: nil)
      owner!
      judge = judge_step(judge) unless judge.nil?
      Judge.new(definition: @definition, receiver: @receiver, client: @client, judge:, instructions:, path: steps,
        purpose: @purpose, payload: @payload, escalate: method(:escalate_with), log_failure: method(:log_failure),
        guard: method(:owner!), harness_type: @harness.type)
    end

    # Whether two outputs agree: compare (a Proc, evaluated against the receiver with the two results and the
    # method's inputs, truthy for agreement) or, without one, whether they are exactly equal.
    # compare is the developer's own code, so its exceptions propagate unwrapped.
    def agree?(first, second, compare = nil)
      owner!
      return Schema.jsonify(first.to_h) == Schema.jsonify(second.to_h) unless compare

      @receiver.instance_exec(first, second, **@inputs, &compare) ? true : false
    end

    # Logs a warning, "[Squishling] Class#method message", to Squishling.config.logger, if there is one.
    def log(message)
      Squishling.config.logger&.warn("[Squishling] #{label} #{message}")
    end

    private

    # Steps made or changed by hand get the params checks a declared step does (no reserved keys).
    def checked_stage(stage)
      stage.each { |step| Params.normalize(step.params, "#{label} harness step params") }
      stage.frozen? ? stage : stage.dup.freeze
    end

    # A judge declaration as the escalation step Judge takes: one step (no priority:), with its type.
    def judge_step(declaration)
      step = ModelPath.normalize_step(declaration, "#{label} judge", extras: Judge::STEP_KEYS)
      ModelPath.single_step!(step, "#{label} judge: a judge is one step, so it")

      type = step.fetch(:type, :chat)
      type = :chat if type.nil?
      step.merge(type: type.is_a?(String) ? type.to_sym : type)
    end

    def owner!
      return if Thread.current.equal?(@owner)

      raise ConfigurationError, "#{label}: a harness must call its run's primitives from the thread it runs on"
    end

    # Makes each attempt of the path until an output passes (see #escalate). The judge's prompt (role :judge)
    # skips squish_validate and names the judge in errors and logs.
    def escalate_with(path, prompt)
      chat = nil
      rejected = nil # [raw content, errors] of the last invalid output
      models = []
      attempt = 1

      while attempt <= path.size
        step = path[attempt - 1]
        models << step.model
        last = attempt == path.size
        reask = !chat.nil? && step == path[attempt - 2]
        if reask
          message = retry_message(rejected.last)
        else
          chat = start_chat(step, prompt)
          message = fresh_message(step, prompt.input, rejected)
        end

        begin
          response = @client.ask(chat, message, step, attempt:, attempts: path.size, role: prompt.role, reask:)
        rescue LLMError => e
          squawk(prompt, path, attempt, nil, e, reask:)
          raise if last

          # A failed request starts the next attempt in a fresh chat, as a new step does.
          chat = nil
          log_failure(prompt.role, attempt, path, e.message)
          attempt += 1
          next
        end

        result, errors = @output_check.call(response.content, prompt)
        if errors.empty?
          squawk(prompt, path, attempt, response, nil, reask:)
          return produce(result, prompt)
        end

        repeated = reask && response.content == rejected.first
        following = next_attempt(path, attempt, repeated)
        error = invalid_output(response, errors, models.size, models.dup, prompt.role == :judge ? "Judge" : "LLM")
        squawk(prompt, path, attempt, response, error, reask:, repeated:, final: following.nil?)
        raise error unless following

        rejected = [response.content, errors]
        log_failure(prompt.role, attempt, path, rejection_reason(errors, response), following:, repeated:)
        attempt = following
      end
    end

    # One round of #samples: the pending samples' requests, sent concurrently, then each outcome recorded.
    def round(pending, attempt)
      jobs = pending.map do |sample|
        step = sample.stage[attempt - 1]
        message = sample_message(sample, step)
        chat = sample.chat
        attempts = sample.stage.size
        reask = sample.reask
        -> { @client.ask(chat, message, step, attempt:, attempts:, role: :sample, sample: sample.name, reask:) }
      end
      outcomes = @client.concurrently(jobs)
      # A setup mistake (or anything that isn't a failed request) ends the call, whichever sample hit it.
      fatal = outcomes.map(&:last).find { |error| error && !error.is_a?(LLMError) }
      raise fatal if fatal

      pending.zip(outcomes).each { |sample, outcome| record(sample, outcome, attempt) }
    end

    # The next message for a sample: a retry in its chat after invalid output, otherwise a fresh chat.
    def sample_message(sample, step)
      sample.reask = !sample.chat.nil?
      return retry_message(sample.rejected.last) if sample.reask

      sample.chat = start_chat(step, @prompt)
      fresh_message(step, @prompt.input, sample.rejected)
    end

    def record(sample, (response, error), attempt)
      stage = sample.stage
      last = attempt == stage.size
      role = "sample #{sample.name}"
      if error
        squawk(@prompt, stage, attempt, nil, error, sample:, reask: sample.reask)
        raise error if last

        sample.chat = nil
        return log_failure(role, attempt, stage, error.message)
      end

      result, errors = @output_check.call(response.content, @prompt)
      if errors.empty?
        squawk(@prompt, stage, attempt, response, nil, sample:, reask: sample.reask)
        return sample.result = produce(result, @prompt)
      end

      # A sample is one step (#samples refuses a stage that mixes them), so a repeat leaves nothing to move on to.
      repeated = sample.reask && response.content == sample.rejected.first
      invalid = invalid_output(response, errors, attempt, stage.first(attempt).map(&:model))
      squawk(@prompt, stage, attempt, response, invalid, sample:, reask: sample.reask, repeated:,
        final: last || repeated)
      raise invalid if last || repeated

      sample.rejected = [response.content, errors]
      log_failure(role, attempt, stage, rejection_reason(errors, response))
    end

    # Remembers a result of the method's own output (a judge's verdict isn't one), so a harness can only return
    # what a primitive produced.
    def produce(result, prompt)
      @produced[result] = true unless prompt.role == :judge
      result
    end

    def start_chat(step, prompt)
      @client.chat(step, instructions: prompt.instructions, schema: prompt.schema.llm_schema)
    end

    # Runs the observability hook, if any, with this attempt's raw output (nil when the call itself failed),
    # the error that ended it (nil when it was accepted), and what was asked. role is nil for escalation
    # attempts, :sample (with the sample's name) or :judge. reask is whether the attempt retried in the same chat,
    # repeated whether it sent back the reply the attempt before it was rejected for, and final whether no attempt
    # follows it.
    def squawk(prompt, path, attempt, response, error, sample: nil, reask: false, repeated: false,
      final: attempt == path.size)
      hook = @definition.squawk
      return unless hook

      step = path[attempt - 1]
      metadata = {
        label:, attempt:, attempts: path.size, final:, repeated:,
        model: response&.model || step.model, provider: step.provider, params: step.request_params(reask),
        input: prompt.input, usage: response&.usage, finish_reason: response&.finish_reason,
        role: sample ? :sample : prompt.role, sample: sample&.name
      }
      Squawk.call(hook, output: response&.content, metadata:, error:)
    end

    # following is the attempt that comes next, which is not the next one when a repeated reply skips ahead.
    def log_failure(role, attempt, path, reason, following: attempt + 1, repeated: false)
      step = path[attempt - 1]
      next_step = path[following - 1]
      action = next_step == step ? "retrying" : "escalating to #{next_step.display_name}"
      who = role ? "#{role} attempt" : "attempt"
      reason = "it repeated the rejected reply: #{reason}" if repeated
      log("#{who} #{attempt} of #{path.size} (#{step.display_name}) failed, #{action}: #{reason}")
    end
  end
end
