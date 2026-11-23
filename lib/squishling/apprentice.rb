# frozen_string_literal: true

module Squishling
  # Apprentice mode: a squished method returns its Ruby result, and the LLM runs alongside it on the same inputs
  # (every call, or those its when: picks), so how well the model does against a mature implementation can be
  # measured before it is trusted with any traffic. The two typed results are compared (compare:, or exact equality)
  # and handed to the report hook, and to the observer when it takes reviews (the Coolhand observer sends the Ruby
  # result as feedback on the request that produced the LLM's). See docs/apprentice.md.
  #
  #   squishling apprentice: { when: ->(**) { rand < 0.05 }, report: ->(match:, metadata:, **) { ... } }
  #
  # A shadow run never changes what the caller gets: its failures (the LLM's, a setup mistake, or an exception from
  # when:, compare: or squish_validate) are reported as the hook's error:, never raised, and squish_fallback is not
  # used. Only the report hook's (and an observer's) own exceptions propagate, on the inline runner.
  module Apprentice
    KEYS = %i[when compare report].freeze
    # The keywords the report hook is called with (it gets those it declares, see KeywordHook).
    REPORT_KEYWORDS = %i[ruby llm match error inputs metadata].freeze
    RUNNERS = %i[inline thread].freeze

    # What an observer's apprentice(review) is told: the call's result from the Ruby path (as plain JSON data),
    # whether the LLM's matched it (nil when the LLM failed or compare: raised), the class of the error that ended
    # the shadow run (nil when it completed; the class only, as an InvalidOutputError carries the model's output), and
    # the request that produced the LLM's result (request_id, see Observer::Call; nil when there is none). Never the
    # model's output.
    Review = Data.define(:label, :call_id, :request_id, :model, :ruby, :match, :error)

    # Runs a job on the caller's thread, as part of the call.
    INLINE = lambda(&:call)

    LOCK = Mutex.new
    private_constant :LOCK

    module_function

    # An apprentice: setting, or nil to inherit: false (off), true (on, with the defaults), or a Hash of when:
    # (a Proc, evaluated against the instance with the inputs as keywords; truthy runs the LLM alongside),
    # compare: (a Proc, evaluated against the instance with the Ruby and LLM results and the inputs as keywords;
    # truthy for a match) and report: (a callable taking keywords, see REPORT_KEYWORDS; false silences an inherited
    # one). A nil value is the same as leaving the key out.
    def normalize(value, where)
      return value if value.nil? || value == false
      return {}.freeze if value == true

      unless value.is_a?(Hash)
        raise ConfigurationError, "#{where} apprentice must be true, false, or a Hash of " \
                                  "#{KEYS.map { |key| "#{key}:" }.join(', ')}, got #{Appendices.describe(value)}"
      end

      settings = known_keys(value, where).compact # nil inherits, as at every other level; false turns a hook off
      %i[when compare].each { |key| check_proc(settings[key], "#{where} apprentice #{key}:") }
      validate_report(settings[:report], "#{where} apprentice")
      settings.freeze
    end

    # The settings with Symbol keys; a key that isn't one of KEYS is a ConfigurationError.
    def known_keys(value, where)
      settings = value.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
      unknown = settings.keys - KEYS
      return settings if unknown.empty?

      raise ConfigurationError, "#{where} apprentice: unknown key(s) #{unknown.map(&:inspect).join(', ')}"
    end

    def check_proc(value, what)
      return if value.nil? || value.is_a?(Proc)

      raise ConfigurationError, "#{what} must be a Proc, got #{Appendices.describe(value)}"
    end

    def validate_report(hook, where, name: "report")
      KeywordHook.validate(hook, where, name:, keywords: REPORT_KEYWORDS)
    end

    # The settings a method runs with, or nil when apprentice mode is off for it: the method's, merged key by key over
    # the class's (false at the method turns it off; a Hash at the method turns it on even when the class has none).
    def resolve(class_level, method_level)
      return nil if method_level == false
      return class_level || nil if method_level.nil?

      (class_level || {}).merge(method_level).freeze
    end

    # A runner: setting: :inline (the default; nil restores it), :thread (the built-in ThreadRunner), or anything that
    # responds to call(job) and runs the job (a Proc taking no arguments) eventually, e.g. on a thread pool.
    def validate_runner(runner, where)
      return :inline if runner.nil?
      return runner if RUNNERS.include?(runner)
      return runner if !runner.is_a?(Symbol) && runner.respond_to?(:call)

      raise ConfigurationError, "#{where} apprentice_runner must be #{RUNNERS.map(&:inspect).join(' or ')}, or " \
                                "respond to call(job), got #{Appendices.describe(runner)}"
    end

    # The configured runner as something that responds to call(job).
    def runner
      case (configured = Squishling.config.apprentice_runner)
      when :inline then INLINE
      when :thread then thread_runner
      else configured
      end
    end

    # The shared ThreadRunner behind apprentice_runner = :thread, started on first use.
    def thread_runner
      LOCK.synchronize { @thread_runner ||= ThreadRunner.new }
    end

    # Waits until the configured runner has finished the shadow runs it was given, for up to timeout seconds (nil:
    # as long as it takes). Returns whether it finished. Only runners that respond to drain (ThreadRunner does) are
    # waited on; the inline runner has nothing pending. For tests, and for a graceful shutdown. Once they have finished,
    # raises the first error a background run held for the caller (see #hold), so a test's setup mistake fails the
    # test; while runs are still pending, the held errors wait for a later drain.
    def drain(timeout: nil)
      current = runner
      return false unless current.respond_to?(:drain) ? current.drain(timeout:) : true

      held = LOCK.synchronize { (@held || []).tap { @held = [] } }
      raise held.first if held.any?

      true
    end

    # Keeps an error a background run can't absorb or raise (see #unabsorbable?) until the next #drain raises it.
    def hold(error)
      LOCK.synchronize { (@held ||= []) << error }
    end

    def clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Errors a shadow run doesn't absorb: those of Squishling::Testing (a test's setup mistake, e.g. an unscripted
    # request), which no squish_fallback absorbs either.
    def unabsorbable?(error)
      !!defined?(Squishling::Testing::Error) && error.is_a?(Squishling::Testing::Error)
    end

    # Called by the Router once a call's Ruby implementation returned its (validated) result, with the Router's
    # frame for the call: starts a shadow run when apprentice mode is on for the method and when: picks this call.
    def shadow(frame, definition, ruby, ruby_seconds)
      settings = definition.apprentice
      return unless settings

      Shadow.new(frame, definition.for_apprentice, settings, ruby, ruby_seconds).start
    end
  end
end
