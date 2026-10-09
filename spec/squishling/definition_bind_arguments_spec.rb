# frozen_string_literal: true

RSpec.describe Squishling::Definition, "#bind_arguments" do
  def klass_with(&body)
    Class.new do
      include Squishling

      purpose "Echo."
      output_schema { string :value }
      squish_when { |**| true }
      class_eval(&body) if body
    end
  end

  def sent_arguments(klass, *args, **kwargs)
    chats = stub_llm({ "value" => "ok" })
    klass.new.call(*args, **kwargs)
    JSON.parse(chats.first.messages.first).fetch("arguments")
  end

  it "names an anonymous splat's values :args" do
    klass = klass_with { def call(*) = nil }

    expect(sent_arguments(klass, 1, "two")).to eq("args" => [1, "two"])
  end

  it "names a splat's values after the parameter" do
    klass = klass_with { def call(*items) = items }

    expect(sent_arguments(klass, 1, 2)).to eq("items" => [1, 2])
  end

  it "binds required and optional positionals before the splat takes the rest" do
    klass = klass_with { def call(first, second = nil, *) = [first, second] }

    expect(sent_arguments(klass, "a", "b", "c", "d")).to eq("first" => "a", "second" => "b", "args" => %w[c d])
  end

  it "sends an empty list for an anonymous splat given no arguments" do
    klass = klass_with { def call(*) = nil }

    expect(sent_arguments(klass)).to eq("args" => [])
  end

  it "merges keyword arguments with an anonymous splat's values" do
    klass = klass_with { def call(*, **) = nil }

    expect(sent_arguments(klass, 1, tone: "formal")).to eq("args" => [1], "tone" => "formal")
  end

  it "binds a plain required positional by its parameter name" do
    klass = klass_with { def call(first) = first }

    expect(sent_arguments(klass, "a")).to eq("first" => "a")
  end

  it "names positionals arg0, arg1 when their parameters have no name" do
    klass = klass_with { def call(first, (second, third)) = [first, second, third] }

    expect(sent_arguments(klass, "a", [1, 2])).to eq("first" => "a", "arg0" => [1, 2])
  end

  it "keeps later arguments on their own names when an unnamed parameter comes first or in the middle" do
    leading = klass_with { def call((a, b), second) = [a, b, second] }
    middle = klass_with { def call(first, (a, b), third) = [first, a, b, third] }

    expect(sent_arguments(leading, [1, 2], "x")).to eq("arg0" => [1, 2], "second" => "x")
    expect(sent_arguments(middle, "f", [1, 2], "t")).to eq("first" => "f", "arg0" => [1, 2], "third" => "t")
  end

  it "routes an anonymous splat method to the LLM when its Ruby implementation is missing" do
    klass = Class.new do
      include Squishling

      purpose "Echo."
      output_schema { string :value }
      def call(*) = raise(NotImplementedError)
    end
    chats = stub_llm({ "value" => "ok" })

    expect(klass.new.call(1, 2).value).to eq("ok")
    expect(JSON.parse(chats.first.messages.first)).to eq("arguments" => { "args" => [1, 2] })
  end
end
