# frozen_string_literal: true

RSpec.describe "Squishling model rotation" do
  def squished(escalation, &)
    Class.new do
      include Squishling

      squishling(escalation:)
      purpose "Classify."
      output_schema { string :label }
      class_eval(&) if block_given?
    end
  end

  # Stubs n valid responses, one per call.
  def stub_ok(calls)
    stub_llm(*Array.new(calls) { { "label" => "ok" } })
  end

  # The model each call tries first, over n calls that all succeed.
  def first_models(klass, calls)
    chats = stub_ok(calls)
    calls.times { klass.call(text: "x") }
    chats.map(&:model)
  end

  # Every model tried by one call whose attempts all fail.
  def models_tried(klass)
    stub_llm(nil, nil, nil, nil, nil)
    klass.new.call(text: "x")
  rescue Squishling::InvalidOutputError => e
    e.models
  end

  let(:tied) do
    [{ model: "a", priority: 1 }, { model: "b", priority: 1 }, { model: "c", priority: 2 }]
  end

  it "rotates which of the models tied on priority goes first" do
    expect(first_models(squished(tied), 5)).to eq(%w[a b a b a])
  end

  it "tries the sibling models in the tier before the next priority" do
    klass = squished(tied)

    expect(models_tried(klass)).to eq(%w[a b c])
    expect(models_tried(klass)).to eq(%w[b a c])
    expect(models_tried(klass)).to eq(%w[a b c])
  end

  it "keeps each model's attempts together" do
    klass = squished([{ model: "a", priority: 1, attempts: 2 }, { model: "b", priority: 1 },
                      { model: "c", priority: 2 }])

    expect(models_tried(klass)).to eq(%w[a a b c])
    expect(models_tried(klass)).to eq(%w[b a a c])
  end

  it "rotates each tier on its own, however many models it has" do
    tiers = [{ model: "a", priority: 1 }, { model: "b", priority: 1 },
             { model: "c", priority: 2 }, { model: "d", priority: 2 }, { model: "e", priority: 2 }]
    klass = squished(tiers)

    expect(Array.new(3) { models_tried(klass) }).to eq([%w[a b c d e], %w[b a d e c], %w[a b e c d]])
  end

  it "rotates the order the steps were declared in, not the order they sort to" do
    klass = squished([{ model: "late", priority: 2 }, { model: "b", priority: 1 }, { model: "a", priority: 1 }])

    expect(models_tried(klass)).to eq(%w[b a late])
    expect(models_tried(klass)).to eq(%w[a b late])
  end

  it "counts each class and each method on its own" do
    a_class = squished(tied)
    b_class = squished(tied)
    chats = stub_ok(5)

    [a_class, a_class, a_class, b_class, a_class].each { |klass| klass.call(text: "x") }

    expect(chats.map(&:model)).to eq(%w[a b a a b])
  end

  it "counts each squished method of a class on its own" do
    klass = squished(tied) do
      squish(:other, escalation: [{ model: "x", priority: 1 }, { model: "y", priority: 1 }]) { string :label }
    end
    chats = stub_ok(4)

    klass.call(text: "x")
    klass.new.other
    klass.call(text: "x")
    klass.new.other

    expect(chats.map(&:model)).to eq(%w[a x b y])
  end

  it "shares the count with squish! on the same method" do
    klass = squished(tied) do
      squish_when { |text:| text == "llm" }

      def call(text:)
        squish!(escalation: [{ model: "p", priority: 1 }, { model: "q", priority: 1 }]) if text == "hand off"
        { label: text }
      end
    end
    chats = stub_ok(3)

    ["llm", "hand off", "llm"].each { |text| klass.new.call(text:) }

    expect(chats.map(&:model)).to eq(%w[a q a])
  end

  it "doesn't rotate a tier with rotate: false" do
    klass = squished([{ model: "a", priority: 1, rotate: false }, { model: "b", priority: 1 }])

    expect(first_models(klass, 3)).to eq(%w[a a a])
  end

  it "leaves a positional escalation and single-model tiers alone" do
    expect(models_tried(squished(%w[a b c]))).to eq(%w[a b c])
    klass = squished([{ model: "a", priority: 1 }, { model: "b", priority: 2 }])

    expect([models_tried(klass), models_tried(klass)]).to eq([%w[a b], %w[a b]])
  end

  it "hands out each turn exactly once when threads race for them" do
    klass = Class.new
    threads = Array.new(8) { Thread.new { Array.new(250) { Squishling::Rotation.advance(klass, :call) } } }
    turns = threads.flat_map(&:value)

    expect(turns.sort).to eq((0...2000).to_a)
  end

  it "falls to the sibling, then the next priority, when a provider fails" do
    klass = squished(tied)
    error = Squishling::LLMError.new("overloaded")
    chats = stub_llm(error, error, { "label" => "ok" })

    expect(klass.call(text: "x").label).to eq("ok")
    expect(chats.map(&:model)).to eq(%w[a b c])
  end

  it "rotates an escalation from the class, the method, or the configured default" do
    Squishling.configure { |c| c.default_escalation = [{ model: "x", priority: 1 }, { model: "y", priority: 1 }] }
    klass = Class.new do
      include Squishling

      purpose "Classify."
      output_schema { string :label }
    end

    expect(first_models(klass, 2)).to eq(%w[x y])
    klass.squishling(escalation: [{ model: "m", priority: 1 }, { model: "n", priority: 1 }])
    expect(first_models(klass, 2)).to eq(%w[m n])
  end

  it "rotates ties declared with the deprecated order:" do
    klass = nil
    expect { klass = squished([{ model: "a", order: 1 }, { model: "b", order: 1 }]) }.to output(/deprecated/).to_stderr

    expect(first_models(klass, 3)).to eq(%w[a b a])
  end

  it "keeps rotating the other tiers when one tier is pinned" do
    tiers = [{ model: "a", priority: 1 }, { model: "b", priority: 1, rotate: false },
             { model: "c", priority: 2 }, { model: "d", priority: 2 }]
    klass = squished(tiers)

    expect([models_tried(klass), models_tried(klass)]).to eq([%w[a b c d], %w[a b d c]])
  end

  it "splits calls evenly across models when they come from several threads" do
    klass = squished(tied)
    chats = stub_ok(40)

    Array.new(8) { Thread.new { 5.times { klass.call(text: "x") } } }.each(&:join)

    expect(chats.map(&:model).tally).to eq("a" => 20, "b" => 20)
  end
end
