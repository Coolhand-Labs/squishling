# frozen_string_literal: true

RSpec.describe "Squishling output contracts" do
  let(:klass) do
    Class.new do
      include Squishling

      squishling escalation: %w[small large]
      instructions "Total the invoice."
      output_schema do
        number :total
        array(:amounts, of: :number)
      end
    end
  end

  let(:wrong) { { "total" => 5, "amounts" => [1, 2] } }
  let(:right) { { "total" => 3, "amounts" => [1, 2] } }

  describe "squish_validate" do
    before do
      klass.squish_validate do |result, **|
        "total must equal the sum of amounts" unless result.total == result.amounts.sum
      end
    end

    it "rejects schema-valid output and escalates with the message" do
      chats = stub_llm(wrong, right)

      expect(klass.call(text: "x").total).to eq(3)
      expect(chats.last.messages.first).to include("total must equal the sum of amounts")
    end

    it "re-asks in the same conversation with the message when a step has more attempts" do
      klass.squishling(escalation: [{ model: "small", attempts: 2 }])
      chats = stub_llm(wrong, right)

      expect(klass.call(text: "x").total).to eq(3)
      expect(chats.size).to eq(1)
      expect(chats.first.messages.last).to include("Your previous response was rejected", "sum of amounts")
    end

    it "raises InvalidOutputError when no model passes" do
      stub_llm(wrong, wrong)

      expect { klass.call(text: "x") }
        .to raise_error(Squishling::InvalidOutputError, /total must equal the sum of amounts/)
    end

    it "receives the typed result and the inputs, evaluated against the instance" do
      seen = nil
      klass.squish_validate do |result, text:|
        seen = [result.class, result.squished?, text, self.class]
        nil
      end
      stub_llm(right)

      klass.call(text: "hi")

      expect(seen).to eq([klass.squishling_definition(:call).schema.result_class, true, "hi", klass])
    end

    {
      "an Array of messages" => [%w[first second], %w[first second]],
      "false" => [false, ["the output was rejected by squish_validate"]]
    }.each do |label, (value, errors)|
      it "treats #{label} as a rejection" do
        klass.squish_validate { |_result, **| value }
        stub_llm(right, right)

        expect { klass.call(text: "x") }.to raise_error(Squishling::InvalidOutputError) { |e| expect(e.errors).to eq(errors) }
      end
    end

    [nil, true, "", [], [nil, " "]].each do |value|
      it "accepts #{value.inspect}" do
        klass.squish_validate { |_result, **| value }
        stub_llm(right)

        expect(klass.call(text: "x").total).to eq(3)
      end
    end

    it "accepts a dry-validation style result" do
      contract_result = Struct.new(:success?, :errors)
      klass.squish_validate do |result, **|
        if result.total == 3
          contract_result.new(true, {})
        else
          contract_result.new(false, { total: ["is wrong"], meta: { source: ["is missing"] }, nil => ["base rule"] })
        end
      end
      chats = stub_llm(wrong, right)

      expect(klass.call(text: "x").total).to eq(3)
      expect(chats.last.messages.first).to include("total is wrong", "meta.source is missing", "- base rule")
    end

    it "accepts a validation result whose errors are a plain list" do
      klass.squish_validate { |result, **| Struct.new(:success?, :errors).new(result.total == 3, ["total is wrong"]) }
      chats = stub_llm(wrong, right)

      expect(klass.call(text: "x").total).to eq(3)
      expect(chats.last.messages.first).to include("total is wrong")
    end

    it "raises ConfigurationError for an unsupported return value" do
      klass.squish_validate { |_result, **| 42 }
      stub_llm(right)

      expect { klass.call(text: "x") }.to raise_error(Squishling::ConfigurationError, /got Integer/)
    end

    it "lets exceptions from the block propagate unwrapped" do
      klass.squish_validate { |_result, **| raise ArgumentError, "mine" }
      klass.squish_fallback { |_error, **| { total: 0, amounts: [] } }
      stub_llm(right)

      expect { klass.call(text: "x") }.to raise_error(ArgumentError, "mine")
    end

    it "is overridden per method and inherited by subclasses" do
      klass.squish(:lenient, validate: ->(_result, **) {}) do
        number :total
        array(:amounts, of: :number)
      end
      stub_llm(wrong, wrong, wrong)

      expect(klass.new.lenient.total).to eq(5)
      expect { Class.new(klass).call }.to raise_error(Squishling::InvalidOutputError, /sum of amounts/)
    end

    it "doesn't run on deterministic or fallback returns" do
      klass.squish_fallback { |_error, **| { total: 9, amounts: [] } }
      klass.class_eval do
        squish_when { |ruby: false, **| !ruby }
        def call(**) = { total: 7, amounts: [] }
      end
      stub_llm(nil, nil)

      expect(klass.call(ruby: true).total).to eq(7)
      expect(klass.call.total).to eq(9)
    end
  end

  describe "conditional schema rules" do
    let(:klass) do
      Class.new do
        include Squishling

        squishling escalation: %w[small large]
        instructions "Review."
        output_schema do
          string :status, enum: %w[approved rejected]
          optional(:reason) { string }
          object(:if) { string :note }
          given(status: "rejected") { string :reason, min_length: 1 }
        end
      end
    end

    it "is validated locally and escalates when broken" do
      chats = stub_llm({ "status" => "rejected", "reason" => nil, "if" => { "note" => "n" } },
        { "status" => "rejected", "reason" => "spam", "if" => { "note" => "n" } })

      expect(klass.call(text: "x").reason).to eq("spam")
      expect(chats.last.messages.first).to include("`/reason` is not a string")
    end

    it "accepts nil where the condition doesn't apply" do
      stub_llm({ "status" => "approved", "reason" => nil, "if" => { "note" => "n" } })

      expect(klass.call(text: "x").reason).to be_nil
    end

    it "is kept out of the schema sent to the provider" do
      chats = stub_llm({ "status" => "approved", "reason" => nil, "if" => { "note" => "n" } })
      klass.call(text: "x")

      sent = chats.first.schema["schema"]
      expect(sent.keys).not_to include("if", "then", "else", "allOf")
      expect(sent["properties"].keys).to eq(%w[status reason if])
      expect(klass.squishling_definition(:call).schema.json_schema).to include("if", "then")
    end

    it "drops an allOf of several conditionals and dependentRequired" do
      schema = Squishling::Schema.new(
        "type" => "object",
        "properties" => { "a" => { "type" => %w[string null] }, "b" => { "type" => %w[string null] } },
        "required" => %w[a b],
        "additionalProperties" => false,
        "allOf" => [{ "if" => {}, "then" => {} }, { "if" => {}, "then" => {}, "else" => {} },
                    { "required" => ["a"] }],
        "dependentRequired" => { "a" => ["b"] },
        "$defs" => { "flag" => { "enum" => [{ "if" => 1 }], "default" => { "then" => 2 } } }
      )

      expect(schema.llm_schema["schema"]).not_to include("dependentRequired")
      expect(schema.llm_schema["schema"]["allOf"]).to eq([{ "required" => ["a"] }])
      expect(schema.json_schema["allOf"].size).to eq(3)
      expect(schema.llm_schema["schema"]["$defs"])
        .to eq("flag" => { "enum" => [{ "if" => 1 }], "default" => { "then" => 2 } })
    end
  end
end
