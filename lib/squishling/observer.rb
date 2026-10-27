# frozen_string_literal: true

module Squishling
  # The around-style hook for tools that must see an LLM request while it is made (a tracing span, a Coolhand
  # declared workload), which squawk's after-the-fact report can't do. An observer is any object responding to
  # around(call), which yields once to make the request. See docs/observers.md.
  #
  # Observers get call metadata (Call) and, back from the yield, the request's token Usage: never the model's
  # output or the method's inputs.
  module Observer
    # What an observer is told about one provider request. handed_off is true when squish! sent the call to the
    # LLM (typically from a rescue) and false when squish_when or a missing implementation did. role is nil for an
    # escalation attempt, :sample (with sample "a", "b", ...) or :judge, like squawk's metadata. attempt and
    # attempts count the (expanded) escalation path the request belongs to. request is :chat, or :judgment for a
    # System One judge.
    Call = Data.define(:label, :purpose, :harness, :handed_off, :role, :sample, :attempt, :attempts, :model, :provider,
      :request)

    # What an observer's block returns: the request's token usage and the model that answered, never the content.
    # A count the provider didn't report is nil.
    Usage = Data.define(:input_tokens, :output_tokens, :model)

    BUILT_IN = %i[coolhand].freeze

    module_function

    # The observer itself, nil (auto-detect), or false (none). A built-in's name (:coolhand) or anything that
    # responds to around is accepted, checked here so a mistake fails at setup, not inside the first request.
    def validate(observer, where)
      return observer if observer.nil? || observer == false

      if observer.is_a?(Symbol)
        return observer if BUILT_IN.include?(observer)

        raise ConfigurationError, "#{where} observer must be one of #{BUILT_IN.map(&:inspect).join(', ')}, " \
                                  "an object that responds to around, or false, got #{observer.inspect}"
      end
      return observer if observer.respond_to?(:around)

      raise ConfigurationError, "#{where} observer must respond to around(call) { ... } (or be false), " \
                                "got #{observer.inspect}"
    end

    # The observer that wraps a request: the configured one, the Coolhand observer when nothing is configured and
    # Coolhand is loaded and set up, or nil.
    def resolve(configured)
      case configured
      when false then nil
      when nil then Observers::Coolhand.new if Observers::Coolhand.available?
      when Symbol then Observers::Coolhand.new
      else configured
      end
    end

    # Runs the request inside the resolved observer, if there is one. The block runs on the calling thread, so
    # for samples it is the worker thread that makes the request. The observer gets the request's Usage back from
    # its yield, not the response, so the model's output can't leave the process through it, and what it returns
    # is ignored, and so is any rescue of the request's error: the error is raised again. An observer that never
    # yields would make the request vanish, and one that yields twice would send it twice: both are setup mistakes.
    def around(call)
      observer = resolve(Squishling.config.observer)
      return yield unless observer

      yielded = false
      response = nil
      failure = nil
      observer.around(call) do
        if yielded
          failure = ConfigurationError.new("#{call.label}: #{observer.class}#around must yield only once")
          raise failure
        end

        yielded = true
        begin
          response = yield
        rescue StandardError => e
          failure = e
          raise
        end
        usage(response)
      end
      unless yielded
        raise ConfigurationError,
          "#{call.label}: the #{observer.class} observer's around must yield to make the request"
      end

      raise failure if failure # an observer can't swallow the request's error: Squishling's taxonomy holds

      response
    end

    # An Adapter::Response carries its token counts in a Hash; a judgment (see Adapter::Base#judge) may carry them in
    # an object with input and output instead. Shared with Budget::Tally; not part of the public API.
    def usage(response)
      tokens = response.respond_to?(:tokens) ? response.tokens : nil
      model = response.respond_to?(:model) ? response.model : nil
      Usage.new(input_tokens: token_count(tokens, :input_tokens, :input),
        output_tokens: token_count(tokens, :output_tokens, :output),
        model: model.respond_to?(:id) ? model.id : model)
    end

    def token_count(tokens, key, reader)
      return tokens[key] if tokens.is_a?(Hash)

      tokens.respond_to?(reader) ? tokens.public_send(reader) : nil
    end
    private_class_method :token_count
  end
end
