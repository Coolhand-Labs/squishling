# frozen_string_literal: true

module Squishling
  module Testing
    # A Squishling adapter that answers from a script instead of a provider (see Script). Install it with
    # Testing.install. It records every request (#requests) and groups them into the chats they belong to
    # (#conversations), and it is safe to ask from the worker threads a harness's samples run on: everything shared
    # is taken under one lock, and replies are chosen by (step, sample, attempt), never by arrival order.
    class Adapter < Squishling::Adapter::Base
      # One chat: its sample (nil unless a harness sample's) and the turns exchanged so far.
      Conversation = Struct.new(:index, :sample, :transcript)

      attr_reader :script

      def initialize(script = Script.new)
        super()
        @script = script
        @lock = Mutex.new
        @requests = []
        @conversations = []
      end

      def judgments?
        true
      end

      # Every request so far, in the order they arrived (Testing::Request).
      def requests
        @lock.synchronize { @requests.dup }
      end

      # The requests of each chat, in order: a retry on the same step shares a chat, a new step starts one.
      def conversations
        requests.select(&:conversation).group_by(&:conversation).sort.map(&:last)
      end

      def requests_for(role: nil, sample: nil)
        requests.select do |request|
          (role.nil? || request.role == role) && (sample.nil? || request.sample == sample.to_s)
        end
      end

      # The models the requests went to, in order (nil for a step that names none).
      def models
        requests.map(&:model)
      end

      # The first request's arguments: what left the process.
      def arguments
        requests.first&.arguments
      end

      def complete(request)
        outcome = @lock.synchronize { answer(request) }
        raise outcome if outcome.is_a?(Exception)

        outcome
      end

      def judge(input, questions:, step:, label:)
        outcome = @lock.synchronize { judged(input, questions, step, label) }
        raise outcome if outcome.is_a?(Exception)

        outcome
      end

      private

      def answer(request)
        call = call_of(request)
        outcome = outcome_for(:chat, call, request.label, request.model)
        conversation = conversation_for(request, call[:sample])
        conversation.transcript.push(*turns(request, outcome)) unless outcome.is_a?(Exception)
        record(request, call, outcome, conversation.index)
        outcome
      end

      def judged(input, _questions, step, label)
        call = { role: :judge, sample: nil, attempt: Observer.current&.attempt, attempts: Observer.current&.attempts,
                 model: step.model, provider: step.provider }
        outcome = outcome_for(:judgment, call, label, step.model)
        payload = Schema.jsonify(input)
        @requests << Request.new(label:, type: :judgment, role: :judge, sample: nil, attempt: call[:attempt],
          attempts: call[:attempts], model: step.model, provider: step.provider, params: step.params,
          cache: step.cache, system_prompt: nil, output_schema: nil, messages: [], conversation: nil, payload:,
          reply: outcome)
        outcome
      end

      def outcome_for(kind, call, label, model)
        rule = @script.rule_for(kind, call)
        item = rule ? rule.take : Rule::EXHAUSTED
        return unscripted(kind, call, label, model, rule) if item.equal?(Rule::EXHAUSTED)

        resolve(item, label)
      end

      def resolve(item, label)
        case item
        when Failure then Failures.build(item.intent, label)
        when Exception, Judgment then item
        when Class then item <= Exception ? item.new : response(item)
        when Reply then Squishling::Adapter::Response.new(content: item.content, model: item.model, tokens: item.usage)
        else response(item)
        end
      end

      def response(content)
        Squishling::Adapter::Response.new(content:)
      end

      def unscripted(kind, call, label, model, rule)
        aimed = call.compact.except(:attempts).map { |key, value| "#{key}: #{value.inspect}" }.join(", ")
        why = if rule
          "its script #{rule.empty? ? 'has no replies' : 'has no answers left (once)'}"
        else
          "no script covers it"
        end
        UnscriptedRequestError.new("#{label}: unscripted #{kind} request to #{model.inspect} (#{aimed}): #{why}. " \
                                   "Scripted: #{@script.describe}")
      end

      # The role, sample, and attempt of the request: from the observer that wraps it, or, when the adapter was
      # installed without one, what the request itself shows.
      def call_of(request)
        observed = Observer.current
        base = { model: request.model, provider: request.provider }
        if observed
          return base.merge(role: observed.role, sample: observed.sample, attempt: observed.attempt,
            attempts: observed.attempts)
        end

        base.merge(role: judge_schema?(request.schema) ? :judge : nil, sample: nil, attempt: nil, attempts: nil)
      end

      def judge_schema?(schema)
        schema["schema"] == Schema.for(Judge::VERDICT_SCHEMA).llm_schema["schema"]
      end

      # A request that continues a chat sends the chat's transcript back, so it finds its conversation by it.
      def conversation_for(request, sample)
        history = request.messages[0...-1]
        found = history.empty? ? nil : @conversations.reverse.find { |c| c.sample == sample && c.transcript == history }
        found || Conversation.new(@conversations.size, sample, []).tap { |chat| @conversations << chat }
      end

      def turns(request, response)
        [{ role: :user, content: request.messages.last.fetch(:content) }, { role: :assistant, content: response.text }]
      end

      def record(request, call, outcome, conversation)
        @requests << Request.new(label: request.label, type: :chat, role: call[:role], sample: call[:sample]&.to_s,
          attempt: call[:attempt], attempts: call[:attempts], model: request.model, provider: request.provider,
          params: request.params, cache: request.cache, system_prompt: request.instructions,
          output_schema: request.schema["schema"], messages: request.messages, conversation:,
          payload: Request.payload_of(request.messages), reply: outcome)
      end
    end

    # The adapter behind Testing.forbid_provider_calls!: any request that reaches it raises ProviderCallError, which
    # is not a Squishling::Error, so a squish_fallback can't absorb it. It remembers the calls that were attempted,
    # for a test that rescued the error.
    class ForbiddenAdapter < Squishling::Adapter::Base
      def initialize
        super
        @lock = Mutex.new
        @attempts = []
      end

      # The labels ("Klass#method") of the calls that reached it.
      def attempts
        @lock.synchronize { @attempts.dup }
      end

      def judgments?
        true
      end

      def complete(request)
        refuse(request.label)
      end

      def judge(_input, label:, **)
        refuse(label)
      end

      private

      def refuse(label)
        @lock.synchronize { @attempts << label }
        raise ProviderCallError, "#{label} reached the provider, but no LLM call was expected. Script it with " \
                                 "Squishling::Testing.install, or fix the code under test"
      end
    end
  end
end
