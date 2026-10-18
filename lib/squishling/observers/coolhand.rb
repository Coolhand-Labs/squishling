# frozen_string_literal: true

module Squishling
  module Observers
    # Declares each request's workload and template to Coolhand (Coolhand.with_context), so Coolhand files the
    # logged call under them instead of matching it to a template. The workload is the squished method
    # ("Class#method"); the template is the call's place in it: "Class#method/squish:L2" (an escalation attempt),
    # "/sample:a", or "/judge". The model isn't in the key: it's on the log, and the place is the stable identity.
    # Used automatically when the coolhand gem is loaded and configured (see Observer.resolve). See docs/coolhand.md.
    class Coolhand
      REPORTER = "squishling"

      # Coolhand rejects keys longer than this.
      MAX_KEY_LENGTH = 255

      # Whether Coolhand is loaded, new enough to declare workloads, and set up to send logs.
      def self.available?
        return false unless defined?(::Coolhand) && ::Coolhand.respond_to?(:with_context)

        configuration = ::Coolhand.respond_to?(:configuration) && ::Coolhand.configuration
        return false unless configuration

        configuration.enabled != false && !configuration.api_key.to_s.strip.empty?
      rescue StandardError
        false # nobody asked for this observer, so a Coolhand that can't say whether it's set up isn't ours to break
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

        ::Coolhand.with_context(
          reporter: REPORTER,
          workload: { key: workload, name: workload, description: call.purpose },
          template: { key: template, name: "#{workload} · #{role_name(call)}" },
          &
        )
      end

      private

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
