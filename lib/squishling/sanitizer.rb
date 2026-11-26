# frozen_string_literal: true

module Squishling
  # Runs the developer's sanitizers over what a call would send (see ClassMethods#squish_sanitize), one full pass per
  # sanitizer, in order. Each is offered every node of the input, parents before their children, as value: (a Hash, an
  # Array, a String, a number, nil, an Image or Document) with its path: ("arguments.pages[1]") and a reject: callable.
  # What it returns replaces the node (its children are then offered), so it can redact a String, drop a Hash's keys,
  # convert a file, or return the node as it was; a returned File, Struct, and so on is read like any input. reject.call
  # records a problem and goes on, so every one is reported together in an InputRejectedError, raised after the pass,
  # before the next pass or any request. Exceptions it raises are the developer's own and propagate as-is, so nothing
  # is sent. Hash keys are not offered. Internal: not part of the public API.
  class Sanitizer
    KEYWORDS = %i[value path reject].freeze
    DEFAULT_REJECTION = "rejected by the sanitizer"

    class << self
      # The sanitizer itself, or nil. It must respond to call and take keywords only, checked here so a mismatch
      # fails at setup rather than inside a call. False isn't a way to switch one off: they all run.
      def validate(hook, where)
        if hook == false
          raise ConfigurationError, "#{where} sanitizer can't be switched off with false: every level's sanitizer runs"
        end

        KeywordHook.validate(hook, where, name: "sanitizer", keywords: KEYWORDS)
      end
    end

    def initialize(hooks, receiver, label, normalizer)
      @hooks = hooks
      @receiver = receiver
      @label = label
      @normalizer = normalizer
    end

    def call(tree)
      @hooks.reduce(tree) { |node, hook| pass(hook, node) }
    end

    private

    def pass(hook, tree)
      @normalizer.restart_count
      rejections = []
      result = tree.to_h { |key, node| [key, visit(hook, node, key.to_s, Payload.join(nil, key), rejections)] }
      raise InputRejectedError.new(rejections, label: @label) if rejections.any?

      result
    end

    # path is where the node is, as the sanitizer is told it; safe is the same for an error message, with any Hash key
    # that isn't a plain identifier masked (see Payload.join).
    def visit(hook, node, path, safe, rejections)
      replaced = replace(hook, node, path, safe, rejections)
      case replaced
      when Hash
        replaced.to_h do |key, item|
          [key, visit(hook, item, "#{path}.#{key}", Payload.join(safe, key), rejections)]
        end
      when Array
        replaced.each_with_index.map do |item, index|
          visit(hook, item, "#{path}[#{index}]", "#{safe}[#{index}]", rejections)
        end
      else replaced
      end
    end

    # What the sanitizer returned is read like any input, even when it is the node itself, changed in place.
    def replace(hook, node, path, safe, rejections)
      keywords = KeywordHook.slice(hook, { value: node, path:, reject: rejector(safe, rejections) })
      result = hook.is_a?(Proc) ? @receiver.instance_exec(**keywords, &hook) : hook.call(**keywords)
      @normalizer.call(result, [], safe)
    end

    # What a sanitizer calls to refuse the call: records each message against the node's path and goes on.
    def rejector(path, rejections)
      lambda do |message = nil|
        messages = Array(message).flatten.map(&:to_s).reject { |text| text.strip.empty? }
        messages = [DEFAULT_REJECTION] if messages.empty?
        messages.each { |text| rejections << InputRejectedError::Rejection.new(path, text) }
        nil
      end
    end
  end
end
