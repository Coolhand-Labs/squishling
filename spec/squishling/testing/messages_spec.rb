# frozen_string_literal: true

require "squishling/testing"

# The test helpers read the retry and escalation messages a Run sends; these fail if the two drift apart.
RSpec.describe "Run::Messages" do
  let(:messages) { Squishling::Run.const_get(:Messages) }
  let(:described_class) { messages }
  let(:sender) { Class.new.tap { |klass| klass.include(messages) }.new }

  it "reads back the errors of a retry message" do
    message = sender.send(:retry_message, ["a is wrong", "b is missing"])

    expect(described_class.parse_retry(message)).to eq(["a is wrong", "b is missing"])
    expect(described_class.parse_retry("hello")).to be_nil
  end

  it "reads back an escalation message: the input, the rejected output, and the errors" do
    message = sender.send(:escalation_message, '{"arguments":{"x":1}}', { "score" => 99 }, ["too high"])
    parsed = described_class.parse_escalation(message)

    expect(parsed).to have_attributes(input: '{"arguments":{"x":1}}', rejected: '{"score":99}', errors: ["too high"])
    expect(described_class.parse_escalation('{"arguments":{}}')).to be_nil
  end
end
