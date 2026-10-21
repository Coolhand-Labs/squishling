# frozen_string_literal: true

module Squishling
  module Testing
    # What the test helpers raise. None of these is a Squishling::Error, so squish_fallback, which absorbs
    # InvalidOutputError and LLMError, can never hide a test setup mistake.
    class Error < StandardError; end

    # A request reached the test adapter and no script covers it.
    class UnscriptedRequestError < Error; end

    # A request reached the provider seam while provider calls were forbidden (see Testing.forbid_provider_calls!).
    class ProviderCallError < Error; end

    # A stub, a fixture, or a direct check was asked for something the method's schema doesn't allow.
    class SetupError < Error; end
  end
end
