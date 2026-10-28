# frozen_string_literal: true

require "simplecov"
require "squishling"

# One conversation as FakeAdapter saw it: the requests that continued the same chat (a retry on the same
# step), with what the first one carried.
class FakeChat
  Response = Struct.new(:content, :model, :tokens, :finish_reason)

  attr_reader :model, :provider, :params, :instructions, :schema, :transcript
  attr_accessor :pending

  def initialize(request)
    @model = request.model
    @provider = request.provider
    @params = request.params
    @instructions = request.instructions
    @schema = request.schema
    @transcript = []
    @pending = false
  end

  # The user messages asked in this chat, in order.
  def messages
    transcript.select { |turn| turn[:role] == :user }.map { |turn| turn[:content] }
  end
end

# A Squishling adapter that replays canned responses. Requests that continue a conversation (the history Squishling
# sends matches a chat's transcript) are grouped into one FakeChat, so specs can assert on chats as they did when
# Squishling held a stateful chat. Exception responses (instances or classes) are raised instead of returned; they
# should be Squishling's own errors, which is what an adapter raises. The squishsum harnesses ask from worker
# threads, so everything shared is taken under a lock.
class FakeAdapter < Squishling::Adapter::Base
  attr_reader :chats
  attr_accessor :judge_calls, :judgments_supported, :responder, :responses, :responses_per_chat, :on_ask, :judgments

  def initialize
    super
    @chats = []
    @judge_calls = []
    @judgments = []
    @judgments_supported = true
    @lock = Mutex.new
  end

  def judgments?
    @judgments_supported
  end

  # A request context the fake carries to worker threads, like an adapter with its own tracing would.
  def capture_context
    Thread.current[:fake_adapter_context]
  end

  def with_context(context)
    Thread.current[:fake_adapter_context] = context
    yield
  ensure
    Thread.current[:fake_adapter_context] = nil
  end

  def complete(request)
    chat = @lock.synchronize { chat_for(request) }
    chat.transcript << { role: :user, content: request.messages.last[:content] }
    on_ask&.call(chat)
    response = responder ? responder.call(request) : take(chat)
    raise response if response.is_a?(Exception) || (response.is_a?(Class) && response < Exception)

    reply = response.is_a?(FakeChat::Response) ? response : FakeChat::Response.new(response)
    tokens = reply.tokens ? reply.tokens.to_h : {}
    Squishling::Adapter::Response.new(content: reply.content, model: reply.model, tokens:,
      finish_reason: reply.finish_reason).tap do |answer|
      chat.transcript << { role: :assistant, content: answer.text }
    end
  ensure
    chat&.pending = false
  end

  Answer = Struct.new(:choice, :probabilities)
  Judgment = Struct.new(:answers) do
    def [](name)
      answers[name]
    end
  end

  def judge(input, questions:, step:, label:)
    @judge_calls << { input:, questions:, label:,
                      options: { model: step.model, provider: step.provider, provider_options: step.params } }
    answer = @lock.synchronize { @judgments.shift }
    raise answer if answer.is_a?(Exception) || (answer.is_a?(Class) && answer < Exception)
    return answer if answer.is_a?(Judgment)

    Judgment.new({ winner: Answer.new(answer.fetch(:choice), answer.fetch(:probabilities)) })
  end

  private

  def chat_for(request)
    history = request.messages[0...-1]
    chat = history.empty? ? start_chat(request) : continued_chat(history, request)
    chat.pending = true
    chat
  end

  def start_chat(request)
    FakeChat.new(request).tap { |chat| @chats << chat }
  end

  def continued_chat(history, request)
    @chats.find { |chat| !chat.pending && chat.transcript == history } ||
      raise("no chat to continue for #{request.model.inspect}: #{history.inspect}")
  end

  def take(chat)
    @lock.synchronize do
      if responses_per_chat
        @per_chat ||= {}
        @per_chat[chat] ||= responses_per_chat.fetch(@chats.index(chat)) do
          raise "unexpected chat ##{@chats.size} (#{chat.model})"
        end.dup
        @per_chat[chat].shift
      else
        responses.shift
      end
    end
  end
end

module LLMHelpers
  # An Adapter::Request for specs that call an adapter directly.
  def adapter_request(schema: nil, **overrides)
    schema ||= Squishling::Schema.new({ type: "object", properties: { label: { type: "string" } },
                                        required: ["label"], additionalProperties: false }).llm_schema
    Squishling::Adapter::Request.new(label: "Klass#call", model: "gpt-test", provider: nil, instructions: "Classify.",
      messages: [{ role: :user, content: "hi" }], schema:, params: {}, **overrides)
  end

  # The FakeAdapter every squished call in the example goes through.
  def fake_adapter
    @fake_adapter || install_fake_adapter
  end

  # Answer successive requests with each response. Returns the chats made, which fill in as requests come.
  def stub_llm(*responses)
    adapter = install_fake_adapter
    adapter.responses = responses
    adapter.chats
  end

  # One list of responses per chat, in the order the chats are created. on_ask is called with the chat before
  # each response is taken.
  def stub_llm_chats(*responses_per_chat, on_ask: nil)
    adapter = install_fake_adapter
    adapter.responses_per_chat = responses_per_chat.map(&:dup)
    adapter.on_ask = on_ask
    adapter.chats
  end

  # Each answer (a winner choice and its probabilities, or an exception) is used for successive judgments.
  # Returns the recorded calls: { input:, questions:, options: }.
  def stub_judgment(*answers)
    fake_adapter.judgments = answers
    fake_adapter.judge_calls
  end

  private

  # A fresh adapter (so a second stub starts with no chats), keeping any judgments already stubbed.
  def install_fake_adapter
    previous = @fake_adapter
    @fake_adapter = FakeAdapter.new
    if previous
      @fake_adapter.judgments = previous.judgments
      @fake_adapter.judge_calls = previous.judge_calls
    end
    Squishling.config.adapter = @fake_adapter
    @fake_adapter
  end
end

RSpec.configure do |config|
  config.include LLMHelpers
  config.disable_monkey_patching!
  config.order = :random
  config.after do
    Squishling.reset_config!
    Squishling.reset_harnesses!
  end
end
