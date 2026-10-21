# frozen_string_literal: true

module Squishling
  module Testing
    # One scripted line: the requests it answers and what they get, in order. The last answer repeats unless the
    # rule is #once. Build them through Script (the block Testing.install yields).
    class Rule
      # What a rule answers. nil means any. kind is :chat (Adapter#complete) or :judgment (Adapter#judge); role is
      # nil (an escalation attempt, or any role when the rule names none), :sample, or :judge.
      Selector = Data.define(:kind, :role, :sample, :model, :provider, :attempt)

      # Rule#take when nothing is left to answer with.
      EXHAUSTED = Object.new.freeze

      attr_reader :selector

      def initialize(selector)
        @selector = selector
        @replies = []
        @taken = 0
        @once = false
      end

      # Answers, in order: a Hash (the model's answer), a String (raw text, malformed or fenced JSON included), nil
      # (an empty response), a Reply (with a model id and token usage), or an Exception (raised as is).
      def reply(*replies)
        @replies.concat(replies)
        self
      end

      # A provider failure named by intent (see Failures::INTENTS).
      def fail(intent)
        @replies << Failure.new(Failures.check!(intent))
        self
      end

      # Running out of answers is an error instead of repeating the last one.
      def once
        @once = true
        self
      end

      def matches?(kind, call)
        selector.kind == kind && fits?(selector.role, call[:role]) && fits?(selector.sample, call[:sample]) &&
          fits?(selector.model, call[:model]) && fits?(selector.provider, call[:provider]) &&
          fits?(selector.attempt, call[:attempt])
      end

      # How narrowly the rule aims, lowest first: rules for a sample or the judge, then those naming the most of a
      # model, a provider, and an attempt, then the rest.
      def specificity
        return 0 if selector.sample || selector.role

        4 - [selector.model, selector.provider, selector.attempt].count { |named| !named.nil? }
      end

      # The next answer, or EXHAUSTED. Called with the script's lock held.
      def take
        return EXHAUSTED if @replies.empty? || (@once && @taken >= @replies.size)

        @replies[[@taken, @replies.size - 1].min].tap { @taken += 1 }
      end

      def empty?
        @replies.empty?
      end

      def describe
        aimed = selector.to_h.compact.except(:kind).map { |key, value| "#{key}: #{value.inspect}" }
        "#{selector.kind} #{aimed.empty? ? 'any' : aimed.join(', ')}"
      end

      private

      def fits?(wanted, actual)
        wanted.nil? || wanted.to_s == actual.to_s
      end
    end

    # The judge's rules: a chat judge answers a verdict, a System One judge a judgment with a confidence.
    class JudgeRules
      CHOICES = %i[a b neither].freeze

      def initialize(chat, judgment)
        @chat = chat
        @judgment = judgment
      end

      # A chat judge's strict verdict (:a, :b, or :neither) and its reason.
      def verdict(choice, reason: "scripted verdict")
        @chat.reply({ "verdict" => check(choice).to_s, "reason" => reason })
        self
      end

      # A System One judgment (type: :judgment) choosing :a, :b, or :neither with that probability; the rest of the
      # probability is split between the other two choices. Pass an Exception to raise it instead.
      def judgment(choice, confidence: 0.95)
        unless choice.is_a?(Exception) || confidence.between?(0, 1)
          raise ArgumentError, "confidence is a probability from 0 to 1, got #{confidence.inspect}"
        end

        @judgment.reply(choice.is_a?(Exception) ? choice : answer(check(choice), confidence))
        self
      end

      # Anything a chat judge's request can answer with (see Rule#reply): off-schema verdicts, raw text, ...
      def reply(*replies)
        @chat.reply(*replies)
        self
      end

      def fail(intent)
        @chat.fail(intent)
        self
      end

      def fail_judgment(intent)
        @judgment.fail(intent)
        self
      end

      def once
        @chat.once
        @judgment.once
        self
      end

      private

      def check(choice)
        return choice.to_sym if CHOICES.include?(choice.to_s.to_sym)

        raise ArgumentError, "a judge choice is one of #{CHOICES.map(&:inspect).join(', ')}, got #{choice.inspect}"
      end

      def answer(choice, confidence)
        others = (1 - confidence) / 2.0
        probabilities = CHOICES.to_h { |key| [key, key == choice ? confidence.to_f : others] }
        Judgment.new({ winner: Answer.new(choice, probabilities) })
      end
    end

    # What a test says the model will do. Rules are matched most specific first (a sample or the judge, then a
    # named model, then step(:any)), and by declaration order within that.
    #
    #   llm.step("flash").reply({ score: 99 }, { score: 5 })   # garbage, then an answer
    #   llm.step("pro").fail(:rate_limit)
    #   llm.sample("a").reply(valid_a)
    #   llm.judge.verdict(:a)
    class Script
      def initialize
        @rules = []
      end

      # Escalation attempts (and any other chat request no sample or judge rule claims) on a model, a provider, or
      # :any model; attempt: narrows it to one attempt of the escalation (counting from 1).
      def step(model = :any, provider: nil, attempt: nil)
        add(:chat, model: model == :any ? nil : model, provider:, attempt:)
      end

      # A harness sample's requests ("a", "b", ...). Each sample has its own queue, so the order the sample threads
      # happen to run in can't change what a sample gets.
      def sample(name)
        add(:chat, role: :sample, sample: name.to_s)
      end

      # The judge of :judged_squishsum, chat or System One.
      def judge
        @judge ||= JudgeRules.new(add(:chat, role: :judge), add(:judgment, role: :judge))
      end

      # The rule that answers a request of this kind, or nil. Called with the lock held (see Adapter).
      def rule_for(kind, call)
        candidates = @rules.each_with_index.select { |rule, _| rule.matches?(kind, call) }
        candidates.min_by { |rule, index| [rule.specificity, index] }&.first
      end

      def describe
        @rules.empty? ? "nothing" : @rules.map(&:describe).join("; ")
      end

      private

      def add(kind, role: nil, sample: nil, model: nil, provider: nil, attempt: nil)
        Rule.new(Rule::Selector.new(kind:, role:, sample:, model:, provider:, attempt:)).tap { |rule| @rules << rule }
      end
    end
  end
end
