# frozen_string_literal: true

module Squishling
  # The requests for one squished method, made through the configured adapter (see Adapter). Squishling owns the
  # conversation: each Conversation holds the system prompt, the output schema, and the messages so far, and every
  # request sends all of it to the adapter.
  class LLMClient
    # One chat on one escalation step. messages are { role:, content: } Hashes, grown by #ask.
    Conversation = Struct.new(:step, :instructions, :schema, :messages)

    # purpose, harness (the harness type), and handed_off (squish! sent the call here) are only told to the observer.
    def initialize(label, purpose:, harness:, handed_off:)
      @label = label
      @purpose = purpose
      @harness = harness
      @handed_off = handed_off
      @adapter = Squishling.config.resolved_adapter
    end

    # Runs each job on its own thread and returns, in order, each job's [value, exception]. Only provider
    # requests run here: parsing, validation, and the developer's callbacks stay on the caller's thread. Fiber
    # storage is inherited by the threads, and the adapter carries over whatever request context it keeps (see
    # Adapter::Base#capture_context). If the caller is interrupted while waiting (a timeout, Thread#raise), the
    # requests still running are stopped rather than left running unobserved.
    def concurrently(jobs)
      return jobs.map { |job| capture(job) } if jobs.size < 2

      context = @adapter.capture_context if @adapter.respond_to?(:capture_context)
      threads = jobs.map do |job|
        thread = Thread.new { with_context(context) { capture(job) } }
        thread.report_on_exception = false
        thread
      end
      threads.map(&:value)
    ensure
      threads&.each { |thread| thread.kill.join if thread.alive? }
    end

    # A fresh conversation on one escalation step, with the system prompt and the strict output schema.
    def chat(step, instructions:, schema:)
      Conversation.new(step, instructions, schema, [])
    end

    # One request in the conversation: the message goes in, and the adapter's answer is kept in it so the next
    # message continues from there. A request that fails leaves the conversation as it was.
    # The adapter raises ConfigurationError for setup mistakes (never retried) and LLMError for failures worth another
    # attempt, which moves on to the next attempt of the escalation (or propagates from the last one).
    # The request runs inside the configured observer (see Observer), on this thread: for samples, the worker's.
    # role is nil for an escalation attempt, :sample (with its name) or :judge; attempt counts in attempts.
    # reask is whether this message is a retry in the same chat (see ModelPath::Step#request_params).
    def ask(chat, message, step, attempt:, attempts:, role: nil, sample: nil, reask: false)
      call = call_info(step, :chat, role:, sample:, attempt:, attempts:)
      Observer.around(call) { complete(chat, message, step, reask) }
    end

    # Whether the adapter can make System One judgments (judges with type: :judgment).
    def judgments?
      @adapter.respond_to?(:judgments?) && @adapter.respond_to?(:judge) && @adapter.judgments?
    end

    # A System One judgment on one step, through the adapter.
    # Judge#check_judgments! has already refused an adapter that can't.
    def judge(input, questions:, step:)
      @adapter.judge(input, questions:, step:, label: @label)
    end

    # #judge inside the configured observer (see Observer), attempt counting in attempts.
    def observed_judgment(input, questions:, step:, attempt:, attempts:)
      call = call_info(step, :judgment, role: :judge, attempt:, attempts:)
      Observer.around(call) { judge(input, questions:, step:) }
    end

    private

    def capture(job)
      [job.call, nil]
    rescue Exception => e # rubocop:disable Lint/RescueException -- re-raised on the caller's thread
      [nil, e]
    end

    def complete(chat, message, step, reask)
      messages = chat.messages + [{ role: :user, content: message }]
      request = Adapter::Request.new(label: @label, model: step.model, provider: step.provider,
        instructions: chat.instructions, messages:, schema: chat.schema, params: step.request_params(reask))
      response = @adapter.complete(request)
      unless response.is_a?(Adapter::Response)
        raise ConfigurationError, "#{@label}: the #{@adapter.class} adapter must return a " \
                                  "Squishling::Adapter::Response from #complete, got #{response.class}"
      end

      chat.messages = messages + [{ role: :assistant, content: response.text }]
      response
    end

    def with_context(context, &)
      return yield unless @adapter.respond_to?(:with_context)

      @adapter.with_context(context, &)
    end

    def call_info(step, request, attempt:, attempts:, role: nil, sample: nil)
      Observer::Call.new(label: @label, purpose: @purpose, harness: @harness, handed_off: @handed_off, role:, sample:,
        attempt:, attempts:, model: step.model, provider: step.provider, request:)
    end
  end
end
