# frozen_string_literal: true

module Squishling
  # How Squishling reaches a model. An adapter is the only code that talks to a provider: Squishling builds a
  # Request (the system prompt, the conversation so far, the strict output schema, the resolved params), the adapter
  # makes one completion and returns a Response. Squishling owns the conversation, the validation, and the retries.
  # Two adapters ship (Adapters::RubyLLM, Adapters::OpenAICompatible); write your own by subclassing Adapter::Base
  # and registering it (Squishling.register_adapter) or assigning an instance to config.adapter. See docs/adapters.md.
  module Adapter
    # One completion to make. messages holds the conversation so far as { role: :user | :assistant, content: String }
    # Hashes, ending with the user message to answer; instructions is the system prompt. schema is the strict
    # structured-output payload ({ "name", "description", "schema", "strict" => true }). params is the resolved
    # generation params: the portable :temperature, :max_output_tokens, and :thinking, plus any provider-specific keys
    # (see Params). label ("Class#method") prefixes the adapter's error messages. model and provider are the step's
    # (nil when it names none).
    Request = Data.define(:label, :model, :provider, :instructions, :messages, :schema, :params)

    # Stands in for an empty reply when the conversation is replayed: some servers reject an empty assistant message.
    EMPTY_REPLY = "(no output)"

    # What a completion returns. content is the model's output: the raw String, or a Hash the adapter already parsed.
    # model is the model id the provider reports. tokens is a Hash of counts (:input_tokens, :output_tokens, and
    # whatever else the provider reports, such as :cache_read_tokens and :thinking_tokens), empty when unknown.
    # finish_reason is why the provider stopped, as a Symbol: :stop, :max_tokens (the output cap cut the reply off),
    # :content_filter, :tool_calls, or the provider's own spelling; nil when it reported none.
    Response = Data.define(:content, :model, :tokens, :finish_reason) do
      # model, tokens, and finish_reason may be left out; nil tokens count as none, and a String or blank
      # finish_reason is made a Symbol or nil. Raises ConfigurationError for tokens that aren't a Hash.
      def initialize(content:, model: nil, tokens: {}, finish_reason: nil)
        tokens ||= {}
        unless tokens.is_a?(Hash)
          raise ConfigurationError, "Adapter::Response tokens must be a Hash, got #{tokens.class}"
        end

        finish_reason = finish_reason.to_s.strip.empty? ? nil : finish_reason.to_sym
        super
      end

      # Whether the provider cut the reply off at the output token cap.
      def truncated?
        finish_reason == :max_tokens
      end

      # The token counts, or nil when the adapter reported none (what squawk's usage: carries).
      def usage
        tokens unless tokens.empty?
      end

      # The output as the text the model will see again in a retry: a Hash an adapter already parsed goes back as
      # JSON, and nothing (or a value JSON can't represent, which is rejected as invalid output anyway) as
      # EMPTY_REPLY.
      def text
        text = content.is_a?(String) ? utf8(content) : generated
        text.strip.empty? ? EMPTY_REPLY : text
      end

      private

      def generated
        content.nil? ? "" : JSON.generate(content)
      rescue JSON::JSONError
        ""
      end

      # Text that goes back out in a request must be valid UTF-8, or serializing the history fails. A reply that
      # wasn't is already reported as invalid output; only its undecodable bytes are replaced here.
      def utf8(text)
        (text.encoding == Encoding::BINARY ? text.dup.force_encoding(Encoding::UTF_8) : text).scrub("?")
      end
    end

    # What an adapter puts on a Squishling error's #cause in place of a provider's own exception (see
    # Base#sanitized_cause): the original's class name and HTTP status in its message, and its backtrace, but none of
    # its message, response, or other state. Not a Squishling::Error: it is never raised, only carried.
    class ProviderFailure < StandardError; end

    # The adapter contract. Subclass it, implement #complete, and raise Squishling's errors:
    #
    #   class MyAdapter < Squishling::Adapter::Base
    #     def complete(request)
    #       reply = MyClient.chat(request.model, request.instructions, request.messages)
    #       Squishling::Adapter::Response.new(content: reply.text, model: reply.model, tokens: reply.usage)
    #     rescue MyClient::Unauthorized
    #       raise configuration_error(request, "MyClient rejected the credentials")
    #     rescue MyClient::Error => e
    #       raise llm_error(request, "MyClient failed (#{e.class})"), cause: sanitized_cause(e, status: e.status)
    #     end
    #   end
    #
    # ConfigurationError is for setup mistakes (bad credentials, an invalid request, an unknown model): it is never
    # retried or escalated. LLMError is for failures worth another attempt (rate limits, 5xx, timeouts, connection
    # errors, a prompt too long for the model): the next attempt, or the last one's caller, sees it. Keep the provider's
    # own message out of both: it can echo request content or part of a key. The same goes for the exception it came
    # from, which error trackers report as the error's #cause: pass `cause: sanitized_cause(e, status:)` rather than
    # letting a raise inside a rescue set a provider exception that carries a response body. Any other exception
    # propagates unwrapped.
    # Which of the two a provider failure is, is the adapter's call (#http_failure maps HTTP statuses, and
    # #context_length? is where an adapter recognizes an overlong prompt); what happens next is Squishling's.
    # Adapters are called from worker threads when a harness takes samples, so they must not share unsynchronized state.
    class Base
      # One completion. Returns an Adapter::Response.
      def complete(_request)
        raise NotImplementedError, "#{self.class} must implement #complete(request)"
      end

      # Whether #judge is supported (judges with type: :judgment).
      def judgments?
        false
      end

      # A System One judgment: input (a Hash) and questions (a Hash of name => question), with the step's model and
      # params. Returns an object answering [name] with an answer that responds to choice and probabilities. label
      # ("Class#method") prefixes error messages. Called as judge(input, questions:, step:, label:).
      def judge(_input, **_options)
        raise ConfigurationError, "#{self.class} doesn't support judgments (type: :judgment judges)"
      end

      # Called on the caller's thread before a harness's sample requests fan out to worker threads. Returns whatever
      # #with_context needs to re-establish the caller's request context (tracing, say) on a worker.
      def capture_context
        nil
      end

      # Runs the block on a worker thread inside the context #capture_context returned.
      def with_context(_context)
        yield
      end

      private

      def configuration_error(request, message)
        ConfigurationError.new("#{request.label}: #{message}")
      end

      def llm_error(request, message)
        LLMError.new("#{request.label}: #{message}")
      end

      # What to pass as `cause:` when raising a Squishling error for a provider's exception: a ProviderFailure naming
      # the original's class and the HTTP status (when given), with the original's backtrace. A provider exception's
      # message and response usually hold the provider's response body, which can echo request content, and error
      # trackers (Sentry, say) report the whole cause chain. Built fresh, never a copy of the original, so none of
      # its state (a Faraday response, say) comes along. Transport errors that carry no body can be passed as they are.
      def sanitized_cause(error, status: nil)
        ProviderFailure.new([error.class, ("HTTP #{status}" if status)].compact.join(", "))
          .tap { |failure| failure.set_backtrace(error.backtrace) }
      end

      # Classifies a provider's HTTP failure, so adapters sort the same status the same way: 408, 413, 429, and 5xx are
      # LLMErrors; 401, 402, 403, 404, and a redirect are ConfigurationErrors (credentials, billing, model or endpoint:
      # nothing a retry fixes); every other 4xx is a RequestRejectedError, unless #context_length? says the input
      # outgrew the model, which is an LLMError too (a bigger model may take it). via names how it failed (the error
      # class, the HTTP status) and is all of the failure that is repeated, with a rejection's status and code tokens.
      # body is the provider's error body, as for #rejected_request_error. A nil status (no HTTP response) or a
      # success status (a reply that was unusable) is an LLMError.
      def http_failure(request, status:, body:, via:)
        case status
        when nil, 100..299, 408, 413, 429, 500.. then llm_error(request, via)
        when 401, 403 then configuration_error(request, "the provider refused the credentials (#{via})")
        when 402 then configuration_error(request, "#{via}: the provider reports a billing or quota problem")
        when 404 then configuration_error(request, "#{via}: check the model name and the endpoint")
        when 300..399 then configuration_error(request, "#{via}: redirects aren't followed; check the endpoint")
        else rejected_or_overlong(request, status:, body:, via:)
        end
      end

      # Whether a rejected request (a 400, or another 4xx not otherwise classified) means the input was too long for the
      # model, which makes it an LLMError rather than a RequestRejectedError. The adapter decides: only it knows how its
      # provider says so. The default recognizes a 400 whose structured error code or type is "context_length_exceeded",
      # never reading the message. Override it to recognize more (and call super); when an adapter can't tell, the
      # failure stays a rejection. status and body are those given to #http_failure.
      def context_length?(status:, body:)
        status == 400 && ErrorBody.context_length?(body)
      end

      def rejected_or_overlong(request, status:, body:, via:)
        return llm_error(request, via) if context_length?(status:, body:)

        rejected_request_error(request, via:, body:, http_status: status)
      end

      # A RequestRejectedError for a request the provider rejected (a 400, or another 4xx). via names how it failed
      # (the error class, the HTTP status); body is the provider's error body (a JSON String, or a Hash with String
      # keys), of which only the status and code tokens are repeated, never its message. http_status, when given, drops
      # a code that only repeats it. The params are pointed at only when the provider named one of them.
      def rejected_request_error(request, via:, body:, http_status: nil)
        found = ErrorBody.read(body, http_status:)
        tokens = found.values_at(:status, :code).compact
        RequestRejectedError.new(
          "#{request.label}: the provider rejected the request (#{[via, *tokens].join(', ')}). " \
          "#{rejection_hint(request.params, found[:param])}",
          provider_status: found[:status], provider_code: found[:code]
        )
      end

      def rejection_hint(params, field)
        named = params.keys.find { |key| names?(field, key.to_s) }
        return "The #{suspects(params)} may be invalid." unless named

        "The provider named the #{named.inspect} param; check its value."
      end

      def suspects(params)
        params.empty? ? "output schema or input" : "params, output schema, or input"
      end

      # Whether the provider's field is the param or inside it (thinking.budget_tokens, stop[0]).
      def names?(field, name)
        !field.nil? && (field == name || field.start_with?("#{name}.", "#{name}["))
      end
    end

    # The adapters by name: the built-ins, registered as they load, and your own (Squishling.register_adapter).
    module Registry
      STORE = NamedRegistry.new("adapter")
      private_constant :STORE

      class << self
        def register_built_in(name, klass)
          STORE.register_built_in(name, klass)
        end

        # Registers an adapter class under a name. It is built with the options given next to its type: (or none).
        def register(name, klass)
          name = STORE.checked_name(name)
          unless implements_complete?(klass)
            raise ConfigurationError, "register_adapter needs a class that implements #complete, got #{klass.inspect}"
          end

          STORE.add(name, klass)
        end

        def fetch(name)
          STORE.fetch(name)
        end

        def names
          STORE.names
        end

        # Forgets the registered adapters; the built-ins stay.
        def reset!
          STORE.reset!
        end

        private

        # A class that defines #complete itself, not one that only inherits Base's placeholder.
        def implements_complete?(klass)
          klass.is_a?(Class) && klass.method_defined?(:complete) && klass.instance_method(:complete).owner != Base
        end
      end
    end

    KEYWORD_KINDS = %i[key keyreq].freeze
    private_constant :KEYWORD_KINDS

    module_function

    # The adapter a config.adapter value names: an instance (anything that responds to complete), a registered name,
    # or a Hash with type: and that adapter's options. Built now, so a mistake (a missing gem, a bad option) fails at
    # setup rather than on the first request.
    def build(value, where)
      case value
      when Symbol, String then instantiate(value, {}, where)
      when Hash
        options = value.transform_keys(&:to_sym)
        raise ConfigurationError, "#{where} adapter: needs a type: (#{type_list})" unless options.key?(:type)

        instantiate(options.delete(:type), options, where)
      else
        return value if value.respond_to?(:complete)

        raise ConfigurationError, "#{where} adapter must be an adapter (responding to complete), one of " \
                                  "#{type_list}, or a Hash with type:, got #{Appendices.describe(value)}"
      end
    end

    # The adapter used when none is configured: RubyLLM's, if the ruby_llm gem is available.
    def detect
      Adapters::RubyLLM.new
    rescue Adapters::RubyLLM::MissingGemError
      raise ConfigurationError, "No adapter is configured and the ruby_llm gem isn't available. " \
                                "Add `gem \"ruby_llm\"` to your Gemfile, or set config.adapter " \
                                "(#{type_list}, or your own adapter)"
    end

    def type_list
      Registry.names.map(&:inspect).join(", ")
    end

    def instantiate(type, options, where)
      name = type.to_s.to_sym
      klass = Registry.fetch(name)
      unless klass
        raise ConfigurationError, "#{where} adapter: unknown adapter #{type.inspect} (available: #{type_list})"
      end

      check_options!(klass, options, name, where)
      options.empty? ? klass.new : klass.new(**options)
    end

    # The keywords the adapter's initialize takes, so a typo is a ConfigurationError rather than an ArgumentError.
    def check_options!(klass, options, name, where)
      known, required = keywords(klass)
      return unless known

      unknown = options.keys - known
      missing = required - options.keys
      return if unknown.empty? && missing.empty?

      problem = unknown.empty? ? "needs #{missing.join(', ')}" : "doesn't take #{unknown.join(', ')}"
      hint = known.empty? ? "" : " (options: #{known.join(', ')})"
      raise ConfigurationError, "#{where} adapter #{name.inspect} #{problem}#{hint}"
    end

    # [all keywords, required keywords] of klass#initialize, or nil when it takes any (**options).
    def keywords(klass)
      parameters = klass.instance_method(:initialize).parameters
      return if parameters.any? { |kind, _| kind == :keyrest }

      [parameters.filter_map { |kind, key| key if KEYWORD_KINDS.include?(kind) },
       parameters.filter_map { |kind, key| key if kind == :keyreq }]
    end
    private_class_method :check_options!, :keywords
    private_class_method :instantiate
  end
end
