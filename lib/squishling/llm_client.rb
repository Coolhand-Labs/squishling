# frozen_string_literal: true

module Squishling
  # RubyLLM requests for one squished method, with RubyLLM's errors mapped onto Squishling's taxonomy.
  class LLMClient
    # Where RubyLLM's own code lives, to tell its ArgumentErrors from the developer's (see #judge).
    RUBY_LLM_LIB = File.dirname(RubyLLM.method(:judge).source_location.first)
    private_constant :RUBY_LLM_LIB

    # Runs each job on its own thread and returns, in order, each job's [value, exception]. Only provider
    # requests run here: parsing, validation, and the developer's callbacks stay on the caller's thread. Fiber
    # storage (RubyLLM's usage owner) is inherited by the threads, and RubyLLM's instrumentation context is
    # carried over the way RubyLLM's own concurrent tool calls do it. Unlike those, the threads don't enter the
    # Rails executor: the caller already holds it, and a second share can deadlock against a pending code reload.
    # If the caller is interrupted while waiting (a timeout, Thread#raise), the requests still running are
    # stopped rather than left running unobserved.
    def self.concurrently(jobs)
      return jobs.map { |job| capture(job) } if jobs.size < 2

      context = instrumentation_context
      threads = jobs.map do |job|
        thread = Thread.new { with_instrumentation_context(context) { capture(job) } }
        thread.report_on_exception = false
        thread
      end
      threads.map(&:value)
    ensure
      threads&.each { |thread| thread.kill.join if thread.alive? }
    end

    def self.capture(job)
      [job.call, nil]
    rescue Exception => e # rubocop:disable Lint/RescueException -- re-raised on the caller's thread
      [nil, e]
    end

    def self.instrumentation_context
      instrumentation = defined?(RubyLLM::Support::Instrumentation) && RubyLLM::Support::Instrumentation
      return unless instrumentation.respond_to?(:current_workflow) && instrumentation.respond_to?(:capture_context)

      [instrumentation.current_workflow, instrumentation.capture_context]
    end

    def self.with_instrumentation_context(context, &)
      return yield unless context

      instrumentation = RubyLLM::Support::Instrumentation
      instrumentation.with_workflow(context.first) { instrumentation.with_context(context.last, &) }
    end

    private_class_method :capture, :instrumentation_context, :with_instrumentation_context

    def initialize(label)
      @label = label
    end

    # A fresh chat on one escalation step, with the system prompt, the strict output schema, and its params.
    def chat(step, instructions:, schema:)
      chat = build_chat(step)
      chat.with_instructions(instructions)
      chat.with_schema(schema)
      apply_params(chat, step.params)
      chat
    end

    # Transient HTTP failures are already retried by RubyLLM (RubyLLM.config.max_retries); anything
    # that still fails is surfaced as an LLMError, which moves on to the next attempt of the
    # escalation (or propagates from the last one). A 400 means the request we built is invalid (an
    # unsupported param, a schema the provider rejects), so it's a setup mistake: escalating or a
    # fallback would otherwise hide it on every call.
    def ask(chat, message, step)
      request(step) { chat.ask(message) }
    end

    # A System One judgment (RubyLLM.judge) on one step. The step's params are sent as provider options.
    # RubyLLM raises ArgumentError for a judgment it can't build (e.g. a model on a provider that takes none, or
    # a provider option its protocol reserves), and a bare RubyLLM::Error without an HTTP response for a provider
    # that doesn't support judgments at all. An ArgumentError from anywhere else (an instrumentation subscriber
    # runs inside the call) is the developer's own and propagates as-is.
    def judge(input, questions:, step:)
      request(step) do
        RubyLLM.judge(input, questions:, provider_options: step.params, **model_options(step))
      rescue RubyLLM::ModelNotFoundError => e
        raise ConfigurationError, "#{@label}: #{e.message}"
      rescue ArgumentError => e
        raise unless raised_by_ruby_llm?(e)

        raise ConfigurationError, "#{@label}: #{e.message}"
      rescue RubyLLM::Error => e
        raise unless e.instance_of?(RubyLLM::Error) && e.response.nil?

        raise ConfigurationError, "#{@label}: #{e.message}"
      end
    end

    private

    def raised_by_ruby_llm?(error)
      error.backtrace&.first&.start_with?("#{RUBY_LLM_LIB}/") || false
    end

    def build_chat(step)
      RubyLLM.chat(**model_options(step))
    rescue RubyLLM::ModelNotFoundError, RubyLLM::ConfigurationError => e
      raise ConfigurationError, "#{@label}: #{e.message}"
    end

    # RubyLLM validates some settings locally (e.g. an impossible thinking budget for the model)
    # and raises ArgumentError before any request is sent.
    def apply_params(chat, params)
      Params.apply(chat, params)
    rescue ArgumentError => e
      raise ConfigurationError, "#{@label}: invalid params #{params.inspect} (#{e.message})"
    end

    def request(step)
      yield
    rescue RubyLLM::ConfigurationError, RubyLLM::UnauthorizedError, RubyLLM::ForbiddenError => e
      raise ConfigurationError, "#{@label}: #{e.class}: #{e.message}"
    rescue RubyLLM::BadRequestError => e
      raise ConfigurationError,
        "#{@label}: the provider rejected the request (#{e.message})#{params_hint(step.params)}"
    rescue RubyLLM::Error, Faraday::Error => e
      raise LLMError, "#{@label}: #{e.class}: #{e.message}"
    end

    # Models missing from RubyLLM's registry (e.g. newly released ones) are only usable when a
    # provider is named, so RubyLLM is told to assume they exist.
    def model_options(step)
      model = step.model
      provider = step.provider
      options = { model:, provider: }.compact
      options[:assume_model_exists] = true if model && provider && !known_model?(model, provider)
      options
    end

    def known_model?(model, provider)
      RubyLLM.models.find(model, provider:)
      true
    rescue RubyLLM::ModelNotFoundError
      false
    end

    def params_hint(params)
      return "" if params.empty?

      ". Check params #{params.inspect}; reasoning models often reject sampling params such as temperature and top_p"
    end
  end
end
