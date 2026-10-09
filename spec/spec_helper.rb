# frozen_string_literal: true

require "simplecov"
require "squishling"

# Stand-in for RubyLLM::Chat: records configuration and replays canned responses.
class FakeChat
  Response = Struct.new(:content, :model, :tokens)

  attr_reader :model, :options, :instructions, :schema, :messages

  def initialize(model:, responses:, on_ask: nil, **options)
    @model = model
    @options = options
    @on_ask = on_ask
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

  # Exception responses (instances or classes) are raised instead of returned. The squishsum harnesses ask
  # from worker threads, so responses shared across chats are taken under a lock.
  SHIFT_LOCK = Mutex.new

  def ask(message)
    @messages << message
    @on_ask&.call(self)
    response = SHIFT_LOCK.synchronize { @responses.shift }
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

  # Stub RubyLLM.chat with one list of responses per chat, in the order the chats are created. on_ask is
  # called with the chat before each response is taken.
  def stub_llm_chats(*responses_per_chat, on_ask: nil)
    chats = []
    allow(RubyLLM).to receive(:chat) do |model: nil, **options|
      responses = responses_per_chat.fetch(chats.size) { raise "unexpected chat ##{chats.size + 1} (#{model})" }
      FakeChat.new(model:, responses: responses.dup, on_ask:, **options).tap { |chat| chats << chat }
    end
    chats
  end

  # Stub RubyLLM.judge; each answer (a winner choice and its probabilities, or an exception) is used for
  # successive judgments. Returns the recorded calls: { input:, questions:, options: }.
  def stub_judgment(*answers)
    calls = []
    allow(RubyLLM).to receive(:judge) do |input, questions:, **options|
      calls << { input:, questions:, options: }
      answer = answers.shift
      raise answer if answer.is_a?(Exception) || (answer.is_a?(Class) && answer < Exception)

      choice = RubyLLM::Choice.new(choice: answer.fetch(:choice), probabilities: answer.fetch(:probabilities),
        confidence: answer.fetch(:probabilities).values.max)
      RubyLLM::Judgment.new(answers: { winner: choice }, model: options[:model])
    end
    calls
  end
end

RSpec.configure do |config|
  config.include LLMHelpers
  config.disable_monkey_patching!
  config.order = :random
  config.after { Squishling.reset_config! }
end
