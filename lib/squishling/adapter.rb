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
    Response = Data.define(:content, :model, :tokens) do
      # model and tokens may be left out; nil tokens count as none. Raises ConfigurationError for tokens that aren't
      # a Hash.
      def initialize(content:, model: nil, tokens: {})
        tokens ||= {}
        unless tokens.is_a?(Hash)
          raise ConfigurationError, "Adapter::Response tokens must be a Hash, got #{tokens.class}"
        end

        super
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

    # The adapter contract. Subclass it, implement #complete, and raise Squishling's errors:
    #
    #   class MyAdapter < Squishling::Adapter::Base
    #     def complete(request)
    #       reply = MyClient.chat(request.model, request.instructions, request.messages)
    #       Squishling::Adapter::Response.new(content: reply.text, model: reply.model, tokens: reply.usage)
    #     rescue MyClient::Unauthorized
    #       raise configuration_error(request, "MyClient rejected the credentials")
    #     rescue MyClient::Error => e
    #       raise llm_error(request, "MyClient failed (#{e.class})")
    #     end
    #   end
    #
    # ConfigurationError is for setup mistakes (bad credentials, an invalid request, an unknown model): it is never
    # retried or escalated. LLMError is for failures worth another attempt (rate limits, 5xx, timeouts, connection
    # errors): the next attempt, or the last one's caller, sees it. Keep the provider's own message out of both: it can
    # echo request content or part of a key. Any other exception propagates unwrapped. Adapters are called from worker
    # threads when a harness takes samples, so they must not share unsynchronized state.
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

      # Appended to the message for a request the provider rejected: a params mistake is the usual cause.
      def params_hint(params)
        return "" if params.empty?

        ". Check params #{params.inspect}; reasoning models often reject sampling params such as temperature and top_p"
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
                                  "#{type_list}, or a Hash with type:, got #{value.inspect}"
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
