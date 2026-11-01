# frozen_string_literal: true

module Squishling
  # A cap on what one squished call may spend across every request it makes: max_total_output_tokens: and
  # max_total_input_tokens:, each a positive Integer. A budget is a Hash of the limits one level declares
  # ({ output:, input: }), layered config -> class -> method -> squish! like generation params. `false` lifts a limit an
  # outer level set. See docs/failures.md.
  module Budget
    # The limit, as declared, for each kind of token, and the counter in Tally#used it is checked against.
    KEYS = { output: :max_total_output_tokens, input: :max_total_input_tokens }.freeze

    module_function

    # One level's limits, validated. A limit left nil is not set at this level.
    def build(label, output: nil, input: nil)
      { output:, input: }.compact.to_h { |kind, value| [kind, check(value, KEYS.fetch(kind), label)] }.freeze
    end

    # value as is when it is a positive Integer, or false (no limit). Raises ConfigurationError otherwise.
    def check(value, name, label)
      return value if value == false || (value.is_a?(Integer) && value.positive?)

      raise ConfigurationError,
        "#{label}: #{name} must be a positive Integer (or false for no limit), got #{value.inspect}"
    end

    # The limits that apply: later levels override earlier ones limit by limit, and false removes a limit.
    def resolve(*layers)
      layers.compact.reduce({}) { |merged, layer| merged.merge(layer) }.select { |_kind, max| max }
    end

    # What one call has spent so far, counted from every response it receives. Requests of one round run on worker
    # threads, so the totals are taken under a lock. A response without token counts adds nothing, so a provider that
    # reports no usage never exhausts a budget.
    class Tally
      def initialize(budget)
        @budget = budget
        @used = { input_tokens: 0, output_tokens: 0 }
        @lock = Mutex.new
      end

      # Counts a response's tokens: an Adapter::Response, or a judgment (see Observer.usage). The input total includes
      # the tokens read from and written to the prompt cache, which adapters report apart from input_tokens.
      def add(response)
        usage = Observer.usage(response)
        @lock.synchronize do
          @used[:input_tokens] += count(usage.input_tokens) + count(usage.cache_read_tokens) +
                                  count(usage.cache_write_tokens)
          @used[:output_tokens] += count(usage.output_tokens)
        end
        response
      end

      # The first limit that has been reached ({ limit:, max:, used: }, used being both totals), or nil.
      def exhausted
        @lock.synchronize do
          @budget.each do |kind, max|
            next if @used.fetch(:"#{kind}_tokens") < max

            return { limit: KEYS.fetch(kind), max:, used: @used.dup }
          end
          nil
        end
      end

      private

      def count(tokens)
        tokens.is_a?(Integer) && tokens.positive? ? tokens : 0
      end
    end
  end
end
