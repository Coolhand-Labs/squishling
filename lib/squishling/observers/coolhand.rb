# frozen_string_literal: true

module Squishling
  module Observers
    # Declares each request's workload and template to Coolhand (Coolhand.with_context), so Coolhand files the
    # logged call under them instead of matching it to a template. The workload is the squished method
    # ("Class#method", described as that, plus "(rescue)" when squish! handed the call over); the template is the
    # call's place in it: "Class#method/squish:L2" (an escalation attempt), "/sample:a", or "/judge". The model
    # isn't in the key: it's on the log, and the place is the stable identity.
    # With coolhand 0.12.0+ (Coolhand.with_context(client_unique_id:)), each log also carries the
    # request's id (Observer::Call#request_id), and an apprentice's review (see Apprentice) is sent as feedback on the
    # request that produced the LLM's result: the Ruby result as the revised output when they differ.
    # Used automatically when the coolhand gem is loaded and configured (see Observer.resolve). See docs/coolhand.md.
    class Coolhand
      REPORTER = "squishling"

      # Coolhand rejects keys longer than this.
      MAX_KEY_LENGTH = 255

      # How long apprentice feedback waits for Coolhand's queued logs to be sent, so the log it names is there first.
      FLUSH_TIMEOUT = 0.5

      # Whether Coolhand is loaded, new enough to declare workloads, and set up to send logs.
      def self.available?
        return false unless defined?(::Coolhand) && ::Coolhand.respond_to?(:with_context)

        configuration = ::Coolhand.respond_to?(:configuration) && ::Coolhand.configuration
        return false unless configuration

        configuration.enabled != false && !configuration.api_key.to_s.strip.empty?
      rescue StandardError
        false # nobody asked for this observer, so a Coolhand that can't say whether it's set up isn't ours to break
      end

      # Whether the coolhand gem can tag a log with Squishling's id for the request, which feedback then names.
      def self.client_ids?
        ::Coolhand.method(:with_context).parameters.any? do |type, name|
          KeywordHook::KEYWORD_TYPES.include?(type) && name == :client_unique_id
        end
      rescue StandardError
        false
      end

      def self.load_library
        require "coolhand"
      end
      private_class_method :load_library

      # Raises ConfigurationError when the coolhand gem is missing or too old to declare workloads.
      def initialize
        self.class.send(:load_library) unless defined?(::Coolhand)
        return if ::Coolhand.respond_to?(:with_context)

        raise ConfigurationError, "observer :coolhand needs a coolhand gem version with Coolhand.with_context " \
                                  "(declared workloads); upgrade the coolhand gem"
      rescue LoadError
        raise ConfigurationError, "observer :coolhand needs the coolhand gem; add `gem \"coolhand\"` to your Gemfile"
      end

      def around(call, &)
        workload = call.label
        template = "#{workload}/#{role_key(call)}"
        return yield unless declarable?(workload) && declarable?(template)

        declared = {
          reporter: REPORTER,
          workload: { key: workload, name: workload, description: description(call) },
          template: { key: template, name: "#{workload} · #{role_name(call)}" }
        }
        declared[:client_unique_id] = call.request_id if call.request_id && self.class.client_ids?
        ::Coolhand.with_context(**declared, &)
      end

      # Sends an apprentice's review (see Apprentice::Review) as feedback on the request that produced the LLM's
      # result, found by its client id: liked when it matched the Ruby result, otherwise disliked with the Ruby result
      # as the revised output. Nothing is sent without such a request (the LLM failed), without a verdict (compare:
      # raised), or with a coolhand gem that can't tag logs with client ids. Coolhand logs in the background, so its
      # queue is flushed first (briefly), for the feedback not to arrive before its log. Coolhand's feedback call
      # doesn't raise.
      def apprentice(review)
        return if review.request_id.nil? || review.match.nil?
        return unless self.class.client_ids? && ::Coolhand.respond_to?(:feedback_service)

        feedback = {
          client_unique_id: review.request_id,
          sentiment: review.match ? "like" : "dislike",
          explanation: "#{review.label}'s Ruby implementation " \
                       "#{review.match ? 'returned the same result' : 'returned the revised output'} " \
                       "(Squishling apprentice)",
          creator_unique_id: REPORTER
        }
        feedback[:revised_output] = JSON.generate(review.ruby) unless review.match
        ::Coolhand.flush(timeout: FLUSH_TIMEOUT) if ::Coolhand.respond_to?(:flush)
        ::Coolhand.feedback_service.create_feedback(feedback)
      end

      private

      # The squished method, marked "(rescue)" when squish! handed it to the LLM. Not the purpose text, which can be
      # a proc that differs per call.
      def description(call)
        return "#{call.label} (apprentice)" if call.apprentice

        call.handed_off ? "#{call.label} (rescue)" : call.label
      end

      # Coolhand rejects, and drops the whole log for, a key over the limit, with surrounding whitespace, or with
      # a leading, trailing or doubled "/".
      def declarable?(key)
        key.length <= MAX_KEY_LENGTH && key == key.strip && !key.start_with?("/") && !key.end_with?("/") &&
          !key.include?("//")
      end

      def role_key(call)
        case call.role
        when :sample then "sample:#{call.sample}"
        when :judge then "judge"
        else "squish:L#{call.attempt}"
        end
      end

      def role_name(call)
        role_key(call).tr(":", " ")
      end
    end
  end
end
