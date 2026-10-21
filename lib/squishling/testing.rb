# frozen_string_literal: true

require "squishling"

require_relative "testing/errors"
require_relative "testing/reply"
require_relative "testing/script"
require_relative "testing/request"
require_relative "testing/observer"
require_relative "testing/adapter"
require_relative "testing/state"
require_relative "testing/checks"
require_relative "testing/stubs"
require_relative "testing/direct"
require_relative "testing/fixtures"
require_relative "testing/helpers"
require_relative "testing/minitest"
require_relative "testing/rspec"

module Squishling
  # Test support, opt-in: `require "squishling/testing"` (it is not loaded with `require "squishling"`, and needs no
  # test framework). A scripted adapter answers in place of a provider and records what was sent to it, plus stubs
  # for the callers of squished methods, schema-driven fixtures, and assertions. See docs/testing.md and the
  # Squishling::Testing::Minitest and ::RSpec mixins.
  module Testing
    class << self
      # Makes the scripted Adapter the one every squished call goes through, and returns it. The block scripts it
      # (see Script); #script adds to it later.
      def install(adapter = Adapter.new)
        yield adapter.script if block_given?
        State.set(:observer, Observer.new(chained_observer(Squishling.config.observer)))
        State.set(:adapter, adapter)
        adapter
      end

      # Any request that reaches the provider seam raises ProviderCallError, naming the squished method. Call it in a
      # suite-wide before hook: a test that forgot to script its calls then fails at the call, not far from it.
      def forbid_provider_calls!
        State.set(:adapter, ForbiddenAdapter.new)
      end

      # Runs the block with provider calls forbidden and returns the calls (the squished methods' labels) that tried
      # to reach the provider, even if the block rescued the error. The adapter is put back afterwards.
      def no_llm_call
        config = Squishling.config
        previous = config.adapter
        guard = ForbiddenAdapter.new
        config.adapter = guard
        begin
          yield
        rescue ProviderCallError
          nil
        ensure
          config.adapter = previous
        end
        guard.attempts
      end

      # See Stubs.result: Klass.call returns a real, schema-validated result of the method's type.
      def stub_result(klass, attrs = nil, method: :call, squished: true, **more, &)
        Stubs.result(klass, Schema.jsonify((attrs || {}).merge(more)), method:, squished:, &)
      end

      # See Stubs.error: Klass.call raises the real error class with realistic attributes.
      def stub_error(klass, kind, **, &)
        Stubs.error(klass, kind, **, &)
      end

      # The messages squish_validate and the schema reject this reply with. See Direct.
      def validate(klass, reply, **inputs)
        Direct.validate(klass, reply, **inputs)
      end

      def fallback_for(klass, error, **inputs)
        Direct.fallback_for(klass, error, **inputs)
      end

      def preview(klass, **inputs)
        Direct.preview(klass, **inputs)
      end

      def valid_reply_for(source, **overrides)
        Fixtures.valid_reply_for(source, **overrides)
      end

      def invalid_reply_for(source, **)
        Fixtures.invalid_reply_for(source, **)
      end

      # A recorder to assign as config.squawk (or give to with_squawk): every attempt's output, error and metadata.
      def capture_squawk
        SquawkCapture.new
      end

      # Runs the block with the capture as config.squawk, and puts the previous hook back. A squawk set on a class or
      # a method still takes precedence over the configured one.
      def with_squawk(capture = capture_squawk)
        config = Squishling.config
        previous = config.squawk
        config.squawk = capture
        yield capture
        capture
      ensure
        config.squawk = previous
      end

      # Puts back what the helpers changed (the adapter and observer) and clears the stubs. The mixins do this
      # after every test; call it yourself with a custom setup.
      def reset!
        Stubs.clear!
        State.restore!
      end

      private

      # An observer the app configured itself (an object, or :coolhand) is kept in the chain; the default Coolhand
      # auto-detection, and our own observer from an earlier install, are not.
      def chained_observer(observer)
        return observer.previous if observer.is_a?(Observer)
        return Squishling::Observer.resolve(observer) if observer.is_a?(Symbol)

        observer if observer.respond_to?(:around)
      end
    end
  end
end
