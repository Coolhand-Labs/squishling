# frozen_string_literal: true

require "squishling"

# Stand-in for RubyLLM::Chat: records configuration and replays canned responses.
class FakeChat
  Response = Struct.new(:content)

  attr_reader :model, :options, :instructions, :schema, :messages

  def initialize(model:, responses:, **options)
    @model = model
    @options = options
    @responses = responses
    @messages = []
  end

  def with_instructions(text)
    @instructions = text
    self
  end

  def with_schema(schema)
    @schema = schema
    self
  end

  def ask(message)
    @messages << message
    Response.new(@responses.shift)
  end
end

module LLMHelpers
  # Stub RubyLLM.chat; each response is returned for successive `ask` calls.
  def stub_llm(*responses)
    chats = []
    allow(RubyLLM).to receive(:chat) do |model: nil, **options|
      FakeChat.new(model:, responses:, **options).tap { |chat| chats << chat }
    end
    chats
  end
end

RSpec.configure do |config|
  config.include LLMHelpers
  config.disable_monkey_patching!
  config.order = :random
  config.after { Squishling.reset_config! }
end
