# frozen_string_literal: true

module Squishling
  module Testing
    # What the helpers changed in Squishling.config (the adapter and observer), remembered so Testing.reset! puts
    # back exactly that: not an app's other settings (which Squishling.reset_config! would also clear), and not a
    # value a test assigned itself after the helpers did.
    module State
      LOCK = Mutex.new
      private_constant :LOCK

      @entries = {} # setting => [what it was before the helpers, what the helpers set it to]
      @config = nil

      class << self
        # Sets a Squishling.config setting, remembering what it was before the first change.
        def set(setting, value)
          LOCK.synchronize do
            config = Squishling.config
            @entries = {} unless config.equal?(@config) # a replaced config is already pristine
            @config = config
            original = original_of(config, setting)
            config.public_send(:"#{setting}=", value)
            @entries[setting] = [original, value]
          end
        end

        # Puts back the settings still holding what the helpers set; leaves a config that has been replaced alone.
        def restore!
          config, entries = LOCK.synchronize do
            [@config, @entries].tap do
              @entries = {}
              @config = nil
            end
          end
          return unless config.equal?(Squishling.config)

          entries.each do |setting, (original, installed)|
            config.public_send(:"#{setting}=", original) if config.public_send(setting).equal?(installed)
          end
        end

        private

        # What to put back: the value before the helpers' first change, unless something else was assigned since.
        def original_of(config, setting)
          current = config.public_send(setting)
          entry = @entries[setting]
          entry && current.equal?(entry.last) ? entry.first : current
        end
      end
    end

    # What a test asked squawk to record: every attempt's raw output, error, and metadata (role, sample, attempt,
    # final, usage, ...), and the report of a call stopped by a token budget or a disagreement (stopped).
    # Use Testing.with_squawk, which puts the previous hook back.
    class SquawkCapture
      Call = Data.define(:output, :error, :metadata)

      def initialize
        @lock = Mutex.new
        @calls = []
      end

      def call(output: nil, error: nil, metadata: nil)
        @lock.synchronize { @calls << Call.new(output:, error:, metadata:) }
      end

      def calls
        @lock.synchronize { @calls.dup }
      end
    end
  end
end
