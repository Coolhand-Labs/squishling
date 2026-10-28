# frozen_string_literal: true

require "squishling/testing"

RSpec.describe Squishling::Testing::Fixtures do
  include Squishling::Testing::RSpec

  let(:json_schema) do
    {
      "type" => "object",
      "properties" => {
        "label" => { "type" => "string", "enum" => %w[bug feature] },
        "score" => { "type" => "integer", "minimum" => 1, "maximum" => 5 },
        "ratio" => { "type" => "number", "exclusiveMinimum" => 0.5 },
        "note" => { "anyOf" => [{ "type" => "string", "minLength" => 3 }, { "type" => "null" }] },
        "tags" => { "type" => "array", "minItems" => 2, "items" => { "type" => "string", "maxLength" => 4 } },
        "when" => { "type" => "string", "format" => "date-time" },
        "ok" => { "type" => "boolean" },
        "owner" => { "$ref" => "#/$defs/owner" },
        "children" => { "type" => "array", "items" => { "$ref" => "#/$defs/owner" } }
      },
      "required" => %w[label score ratio note tags when ok owner children],
      "additionalProperties" => false,
      "$defs" => {
        "owner" => {
          "type" => "object",
          "properties" => { "name" => { "type" => "string" },
                            "next" => { "anyOf" => [{ "$ref" => "#/$defs/owner" }, { "type" => "null" }] } },
          "required" => %w[name next],
          "additionalProperties" => false
        }
      }
    }
  end
  let(:schema) { Squishling::Schema.for(json_schema) }
  let(:klass) do
    raw = json_schema
    Class.new do
      include Squishling

      purpose "Rate."
      output_schema raw
    end
  end

  describe ".valid_reply_for" do
    it "derives a reply the schema accepts from a class, a Schema, or a Hash" do
      [klass, schema, json_schema].each do |source|
        reply = valid_reply_for(source)

        expect(schema.validate(reply)).to eq([])
        expect(reply).to include("label" => "bug", "score" => 1, "tags" => %w[exam exam])
      end
    end

    it "takes overrides for top-level attributes" do
      reply = valid_reply_for(klass, score: 4, label: "feature")

      expect(reply).to include("score" => 4, "label" => "feature")
    end

    it "builds a reply that types as the method's result" do
      result = klass.new.then { |instance| Squishling::Testing.stub_result(klass, valid_reply_for(klass)) && instance.call }

      expect(result.score).to eq(1)
    end

    it "explains a schema it can't satisfy on its own" do
      pattern = { "type" => "object", "properties" => { "code" => { "type" => "string", "pattern" => "^[A-Z]{3}$" } },
                  "required" => ["code"], "additionalProperties" => false }

      expect { valid_reply_for(pattern) }.to raise_error(Squishling::Testing::SetupError, /pass the attributes/)
      expect(valid_reply_for(pattern, code: "ABC")).to eq({ "code" => "ABC" })
    end
  end

  describe ".invalid_reply_for" do
    it "breaks one property so the schema rejects the reply" do
      %i[label score ratio note tags ok when owner].each do |key|
        reply = invalid_reply_for(klass, violating: key)

        expect(schema.validate(reply)).not_to be_empty, "expected #{key} to be broken"
      end
    end

    it "breaks the property out of its range by default for a bounded number" do
      expect(invalid_reply_for(klass, violating: :score)["score"]).to eq("not valid").or(satisfy { |v| v != 3 })
    end

    it "uses the break asked for" do
      expect(invalid_reply_for(klass, violating: :score, how: :range)["score"]).to eq(0)
      expect(invalid_reply_for(klass, violating: :label, how: :enum)["label"]).to eq("not in the enum")
      expect(invalid_reply_for(klass, violating: :score, how: :missing)).not_to include("score")
      expect(invalid_reply_for(klass, violating: :score, how: :null)).to include("score" => nil)
    end

    it "keeps the other attributes valid and takes overrides" do
      reply = invalid_reply_for(klass, violating: :score, label: "feature")

      expect(reply).to include("label" => "feature")
      expect(schema.validate(reply).join).to include("score")
    end

    it "rejects an attribute the schema doesn't have, and a break that doesn't apply" do
      expect do
        invalid_reply_for(klass, violating: :nope)
      end.to raise_error(Squishling::Testing::SetupError, /no property/)
      expect { invalid_reply_for(klass, violating: :ok, how: :range) }
        .to raise_error(Squishling::Testing::SetupError, /couldn't find a value/)
      expect { invalid_reply_for(klass, violating: :ok, how: :sideways) }.to raise_error(ArgumentError, /how:/)
    end
  end

  describe "other schema shapes" do
    it "merges allOf parts and infers a type from properties or items" do
      shape = {
        "type" => "object",
        "properties" => {
          "merged" => { "allOf" => [{ "type" => "object", "properties" => { "a" => { "type" => "string" } } },
                                    { "type" => "object", "properties" => { "b" => { "type" => "integer" } } }] },
          "untyped" => { "properties" => { "x" => { "type" => "boolean" } } },
          "list" => { "items" => { "type" => "string" } },
          "nothing" => { "type" => "null" },
          "pinned" => { "const" => "fixed" }
        },
        "required" => %w[merged untyped list nothing pinned], "additionalProperties" => false
      }

      expect(valid_reply_for(shape)).to eq("merged" => { "a" => "example", "b" => 0 }, "untyped" => { "x" => true },
        "list" => [], "nothing" => nil, "pinned" => "fixed")
    end

    it "breaks string and array lengths" do
      bounded = {
        "type" => "object",
        "properties" => { "code" => { "type" => "string", "minLength" => 2, "maxLength" => 3 },
                          "tags" => { "type" => "array", "items" => { "type" => "string" }, "maxItems" => 1 } },
        "required" => %w[code tags], "additionalProperties" => false
      }

      expect(invalid_reply_for(bounded, violating: :code, how: :range)["code"].length).to be_between(0, 4)
      expect(Squishling::Schema.for(bounded).validate(invalid_reply_for(bounded, violating: :tags,
        how: :range))).not_to be_empty
    end
  end

  it "accepts a squished class's schema through the helpers module" do
    expect(Squishling::Testing.invalid_reply_for(klass, violating: :score)).to be_a(Hash)
  end
end
