# frozen_string_literal: true

require "rspec/expectations"
require "squishling"

# be_squishling_valid: passes when Squishling.verify finds no problems, and fails with its report.
#   expect(Squishling).to be_squishling_valid   # every squished class (eager load first in Rails)
#   expect(InvoiceParser).to be_squishling_valid
#   expect([InvoiceParser, Triage]).to be_squishling_valid
RSpec::Matchers.define :be_squishling_valid do
  match do |actual|
    @report = actual.equal?(Squishling) ? Squishling.verify : Squishling.verify(actual)
    @report.ok?
  end

  failure_message { @report.to_s }
  failure_message_when_negated { "expected Squishling.verify to find problems, but it found none" }
end
