# frozen_string_literal: true

require "simplecov"
require "squishling"

# Stand-in for RubyLLM::Chat: records configuration and replays canned responses.
class FakeChat
  Response = Struct.new(:content, :model, :tokens)

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

  # Generation settings applied through RubyLLM's setters, recorded for assertions.
  def generation
    @generation ||= {}
  end

  def with_temperature(temperature)
    generation[:temperature] = temperature
    self
  end

  def with_max_output_tokens(max_output_tokens)
    generation[:max_output_tokens] = max_output_tokens
    self
  end

  # Mirrors RubyLLM 2.0: with_thinking(true | false) or with_thinking(effort:, budget:, display:).
  def with_thinking(enabled = true, **options) # rubocop:disable Style/OptionalBooleanParameter -- mirrors RubyLLM
    generation[:thinking] = options.empty? ? enabled : options
    self
  end

  def with_provider_options(provider_options)
    generation[:provider_options] = provider_options
    self
  end

  # Exception responses (instances or classes) are raised instead of returned.
  def ask(message)
    @messages << message
    response = @responses.shift
    raise response if response.is_a?(Exception) || (response.is_a?(Class) && response < Exception)

    response.is_a?(Response) ? response : Response.new(response)
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
