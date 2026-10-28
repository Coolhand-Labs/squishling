# frozen_string_literal: true

module Squishling
  module Adapters
    # Sends requests through RubyLLM (https://rubyllm.com): OpenAI, Anthropic Claude, Google Gemini, AWS Bedrock,
    # OpenRouter, and any other provider it supports. Configure provider API keys in RubyLLM as usual
    # (RubyLLM.configure); transient HTTP failures are retried by RubyLLM itself (RubyLLM.config.max_retries).
    # The ruby_llm gem is loaded when the adapter is built, so Squishling doesn't depend on it. See docs/adapters.md.
    class RubyLLM < Adapter::Base
      MINIMUM_VERSION = Gem::Version.new("2.1")

      # The ruby_llm gem isn't installed (Adapter.detect tells that apart from a gem that is, but too old).
      class MissingGemError < ConfigurationError; end

      # Raises ConfigurationError when the ruby_llm gem is missing.
      def initialize
        super
        require "ruby_llm"
        check_version!
        @lib = gem_lib_dir
      rescue LoadError => e
        raise unless e.path == "ruby_llm"

        raise MissingGemError, "adapter :ruby_llm needs the ruby_llm gem; add `gem \"ruby_llm\"` to your Gemfile"
      end

      # One chat on the request's model: the system prompt, the strict output schema, and the params, then the
      # conversation so far replayed, answering its last message. Models missing from RubyLLM's registry (e.g. newly
      # released ones) are only usable when a provider is named, so RubyLLM is told to assume they exist.
      def complete(request)
        chat = build_chat(request)
        *history, last = request.messages
        history.each { |message| chat.add_message(role: message[:role], content: message[:content]) }
        response = guarded(request) { chat.ask(last[:content]) }
        Adapter::Response.new(content: response.content, model: response.model, tokens: tokens_of(response),
          finish_reason: response.finish_reason)
      end

      def judgments?
        true
      end

      # A System One judgment (RubyLLM.judge) on one step. The step's params are sent as provider options.
      # RubyLLM raises ArgumentError for a judgment it can't build (e.g. a model on a provider that takes none, or
      # a provider option its protocol reserves), and a bare RubyLLM::Error without an HTTP response for a provider
      # that doesn't support judgments at all. An ArgumentError from anywhere else (an instrumentation subscriber
      # runs inside the call) is the developer's own and propagates as-is.
      def judge(input, questions:, step:, label:)
        request = judgment_request(label, step)
        guarded(request) do
          ::RubyLLM.judge(input, questions:, provider_options: step.params, **model_options(step.model, step.provider))
        rescue ::RubyLLM::ModelNotFoundError, ::RubyLLM::Error, ArgumentError => e
          raise unless setup_failure?(e)

          raise ConfigurationError, "#{label}: #{e.message}"
        end
      end

      # RubyLLM's instrumentation context (the workflow and its captured context) is carried to the worker threads
      # the way RubyLLM's own concurrent tool calls do it. Unlike those, the threads don't enter the Rails executor:
      # the caller already holds it, and a second share can deadlock against a pending code reload.
      def capture_context
        instrumentation = ::RubyLLM::Support::Instrumentation if defined?(::RubyLLM::Support::Instrumentation)
        return unless instrumentation.respond_to?(:current_workflow) && instrumentation.respond_to?(:capture_context)

        [instrumentation.current_workflow, instrumentation.capture_context]
      end

      def with_context(context, &)
        return yield unless context

        instrumentation = ::RubyLLM::Support::Instrumentation
        instrumentation.with_workflow(context.first) { instrumentation.with_context(context.last, &) }
      end

      private

      def tokens_of(response)
        response.tokens ? response.tokens.to_h : {}
      end

      # Whether a failure from RubyLLM.judge is a judgment RubyLLM can't make, rather than a failed request or the
      # developer's own error.
      def setup_failure?(error)
        case error
        when ::RubyLLM::ModelNotFoundError then true
        when ArgumentError then raised_by_ruby_llm?(error)
        else error.instance_of?(::RubyLLM::Error) && error.response.nil?
        end
      end

      def judgment_request(label, step)
        Adapter::Request.new(label:, model: step.model, provider: step.provider, instructions: nil, messages: [],
          schema: nil, params: step.params)
      end

      def build_chat(request)
        chat = ::RubyLLM.chat(**model_options(request.model, request.provider))
        chat.with_instructions(request.instructions)
        chat.with_schema(request.schema)
        apply_params(chat, request)
        chat
      rescue ::RubyLLM::ModelNotFoundError, ::RubyLLM::ConfigurationError => e
        raise configuration_error(request, e.message)
      end

      # RubyLLM validates some settings locally (e.g. an impossible thinking budget for the model)
      # and raises ArgumentError before any request is sent.
      def apply_params(chat, request)
        params = request.params
        rest = params.except(:temperature, :thinking, :max_output_tokens)
        chat.with_temperature(params[:temperature]) if params.key?(:temperature)
        chat.with_max_output_tokens(params[:max_output_tokens]) if params.key?(:max_output_tokens)
        apply_thinking(chat, params[:thinking]) if params.key?(:thinking)
        chat.with_provider_options(rest) if rest.any?
      rescue ArgumentError => e
        raise configuration_error(request, "invalid params #{params.keys.inspect} (#{e.message})")
      end

      # true: the model's default thinking; false: off; a Hash: { effort:, budget:, display: }.
      def apply_thinking(chat, thinking)
        thinking.is_a?(Hash) ? chat.with_thinking(**thinking) : chat.with_thinking(thinking)
      end

      # Transient HTTP failures are already retried by RubyLLM; anything that still fails is surfaced as an
      # LLMError, which moves on to the next attempt of the escalation (or propagates from the last one). A 400
      # means the request we built is invalid (an unsupported param, a schema the provider rejects), so it's a
      # setup mistake: escalating or a fallback would otherwise hide it on every call.
      # A provider's or transport's own message never goes into ours: a provider can echo request content or part of
      # an API key in it, and ours reach logs and error trackers. The original stays as #cause for whoever
      # chooses to read it. RubyLLM's own ConfigurationError is local (it names a missing setting), so it is kept.
      def guarded(request)
        yield
      rescue ::RubyLLM::ConfigurationError => e
        raise configuration_error(request, "#{e.class}: #{e.message}")
      rescue ::RubyLLM::UnauthorizedError, ::RubyLLM::ForbiddenError => e
        raise configuration_error(request, describe_failure(e))
      rescue ::RubyLLM::BadRequestError => e
        raise rejected_request_error(request, via: describe_failure(e), body: response_field(e.response, :body),
          http_status: response_field(e.response, :status))
      rescue ::RubyLLM::Error, Faraday::Error => e
        raise llm_error(request, describe_failure(e))
      end

      # The error's class and HTTP status, when it has one, which is all of it that is ours to repeat.
      def describe_failure(error)
        status = response_field(error.response, :status)
        status ? "#{error.class}, HTTP #{status}" : error.class.to_s
      end

      # A field of an error's response, which is a Faraday::Response, or a Hash for a Faraday error.
      def response_field(response, field)
        response.is_a?(Hash) ? response[field] : (response.public_send(field) if response.respond_to?(field))
      end

      def model_options(model, provider)
        options = { model:, provider: }.compact
        options[:assume_model_exists] = true if model && provider && !known_model?(model, provider)
        options
      end

      def known_model?(model, provider)
        ::RubyLLM.models.find(model, provider:)
        true
      rescue ::RubyLLM::ModelNotFoundError
        false
      end

      def raised_by_ruby_llm?(error)
        error.backtrace&.first&.start_with?("#{@lib}/") || false
      end

      # The adapter uses RubyLLM 2.1 APIs (judgments, with_max_output_tokens, Tokens#to_h), and no gemspec pins it.
      def check_version!
        version = Gem.loaded_specs["ruby_llm"]&.version
        return if version.nil? || version >= MINIMUM_VERSION

        raise ConfigurationError, "adapter :ruby_llm needs ruby_llm #{MINIMUM_VERSION} or newer, got #{version}"
      end

      # Where RubyLLM's own code lives, to tell its ArgumentErrors from the developer's (see #judge).
      # It is read from the file that was loaded, which is the path RubyLLM's backtrace frames carry.
      def gem_lib_dir
        entry = $LOADED_FEATURES.find { |feature| feature.end_with?("/lib/ruby_llm.rb") }
        return File.dirname(entry) if entry

        File.join(Gem.loaded_specs.fetch("ruby_llm").full_gem_path, "lib")
      end
    end

    Adapter::Registry.register_built_in(:ruby_llm, RubyLLM)
  end
end
