# frozen_string_literal: true

module Squishling
  class Harness
    # The default: each attempt of the escalation, in order, until an output passes the schema and squish_validate.
    class Escalation < Base
      def self.normalize_options(given, label)
        if given.transform_keys(&:to_sym).key?(:compare)
          raise ConfigurationError, "#{label}: compare: only applies to the squishsum harnesses"
        end

        super
      end

      def call(run)
        run.escalate
      end
    end

    Registry.register_built_in(:escalation, Escalation)
  end
end
