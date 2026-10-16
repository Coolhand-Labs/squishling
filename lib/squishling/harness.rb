# frozen_string_literal: true

module Squishling
  # How a squished call uses its escalation. Declared as a type, or a Hash with the type and its options:
  #   harness: :squishsum
  #   harness: { type: :judged_squishsum, judge: "claude-opus-5-5", compare: ->(a, b, **) { a.team == b.team } }
  # :escalation (the default) tries each attempt in order until an output passes. :squishsum asks the first
  # escalation step twice, concurrently, and accepts the output only when both samples agree. :judged_squishsum
  # hands disagreeing samples to a judge that picks one or rejects both. Your own types are registered with
  # Squishling.register_harness (see Harness::Base).
  class Harness
    DEFAULT_JUDGE_INSTRUCTIONS = <<~TEXT.strip
      You are an impartial judge. Two independent attempts at the same operation returned different outputs,
      candidate "a" and candidate "b". Both already match the required output format, so judge only their
      content. You are given the operation's purpose and its input. Decide which candidate correctly and
      faithfully carries out the purpose for this input. If both do (for example, they differ only in
      wording), choose either one, preferring "a". Choose "neither" only when both are wrong or you can't tell
      whether either is correct. Never combine them or invent a third answer.
    TEXT

    # The type's validated options (frozen), and the Base subclass that runs it.
    attr_reader :type, :klass, :options

    class << self
      def normalize(value, label)
        case value
        when Symbol, String then build(type_for(value, label), {}, label)
        when Hash then from_hash(value, label)
        else
          raise ConfigurationError, "#{label}: harness must be one of #{types.join(', ')} or a Hash with type:, " \
                                    "got #{value.inspect}"
        end
      end

      # Every registered type: the built-ins, then your own in registration order.
      def types
        Registry.names
      end

      private

      def from_hash(hash, label)
        hash = hash.transform_keys(&:to_sym)
        raise ConfigurationError, "#{label}: a harness Hash needs type:" unless hash.key?(:type)

        build(type_for(hash[:type], label), hash.except(:type), label)
      end

      def build(type, options, label)
        klass = Registry.fetch(type)
        new(type:, klass:, options: klass.normalize_options(options, label))
      end

      def type_for(value, label)
        type = value.to_s.to_sym if value.is_a?(Symbol) || value.is_a?(String)
        return type if Registry.fetch(type)

        raise ConfigurationError, "#{label}: unknown harness #{value.inspect} (use #{types.join(', ')})"
      end
    end

    def initialize(type:, klass: Registry.fetch(type), options: {})
      @type = type
      @klass = klass
      @options = options.freeze
      freeze
    end

    DEFAULT = new(type: :escalation)

    def squishsum?
      %i[squishsum judged_squishsum].include?(type)
    end

    def judged?
      type == :judged_squishsum
    end
  end
end
