# frozen_string_literal: true

module Squishling
  module Testing
    # Tells the test adapter which request it is answering. An Adapter::Request carries no role, sample, or attempt,
    # but the Observer::Call that wraps it does, on the thread that makes the request: this observer keeps it where
    # Adapter#complete can read it, and passes the request on to any observer the app configured.
    class Observer
      KEY = :squishling_testing_call

      # The call being made on this thread, or nil outside a request.
      def self.current
        Thread.current[KEY]
      end

      attr_reader :previous

      def initialize(previous = nil)
        @previous = previous
      end

      def around(call, &)
        outer = Thread.current[KEY]
        Thread.current[KEY] = call
        @previous ? @previous.around(call, &) : yield
      ensure
        Thread.current[KEY] = outer
      end
    end
  end
end
