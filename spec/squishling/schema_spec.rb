# frozen_string_literal: true

RSpec.describe Squishling::Schema do
  let(:json_schema) do
    {
      "type" => "object",
      "properties" => { "label" => { "type" => "string" } },
      "required" => ["label"],
      "additionalProperties" => false
    }
  end

  describe "#validate" do
    it "rejects a non-object when a raw Hash schema omits type: object" do
      schema = described_class.new(json_schema.except("type"))

      expect(schema.validate("hello")).to eq(["root must be an object"])
      expect(schema.validate([1, 2])).to eq(["root must be an object"])
      expect(schema.validate({ "label" => "ok" })).to be_empty
    end
  end

  describe "eager $ref resolution" do
    def with_ref(ref, defs: { "tag" => { "type" => "string" } })
      { "type" => "object", "properties" => { "label" => { "$ref" => ref } }, "required" => ["label"],
        "additionalProperties" => false, "$defs" => defs }
    end

    it "keeps working for a reference to a local $defs entry" do
      schema = described_class.new(with_ref("#/$defs/tag"))

      expect(schema.validate({ "label" => "ok" })).to be_empty
      expect(schema.validate({ "label" => 1 })).not_to be_empty
    end

    it "resolves a $ref inside $defs and a recursive definition" do
      defs = { "tag" => { "type" => "string" },
               "node" => { "type" => "object", "properties" => { "next" => { "$ref" => "#/$defs/node" } } } }
      raw = with_ref("#/$defs/tag", defs:).merge("allOf" => [{ "$ref" => "#/$defs/node" }])

      expect { described_class.new(raw) }.not_to raise_error
    end

    it "raises a ConfigurationError for a remote $ref at build, without fetching it" do
      expect { described_class.new(with_ref("https://example.com/schemas/tag.json")) }
        .to raise_error(Squishling::ConfigurationError, %r{\$ref that can.t be resolved.*schemas/tag\.json})
    end

    it "raises a ConfigurationError for a $ref to a $defs entry that doesn't exist" do
      expect { described_class.new(with_ref("#/$defs/missing")) }
        .to raise_error(Squishling::ConfigurationError, /\$ref that can't be resolved/)
    end

    it "finds an unresolvable $ref nested in a subschema" do
      raw = { "type" => "object", "additionalProperties" => false, "required" => ["list"],
              "properties" => { "list" => { "type" => "array", "items" => { "$ref" => "http://example.com/x" } } } }

      expect { described_class.new(raw) }.to raise_error(Squishling::ConfigurationError)
    end
  end

  describe ".for" do
    it "returns the same Schema for the same raw schema" do
      expect(described_class.for(json_schema)).to equal(described_class.for(json_schema))
    end

    it "holds raw schemas weakly, so a reloaded schema class can be collected" do
      expect(described_class::CACHE).to be_a(ObjectSpace::WeakKeyMap)
    end

    it "does not cache a schema that failed to build" do
      bad = { "type" => "object", "properties" => { "a" => { "$ref" => "http://example.com/x" } } }

      2.times { expect { described_class.for(bad) }.to raise_error(Squishling::ConfigurationError) }
    end
  end

  describe "accepted output_schema forms" do
    it "accepts any object that responds to to_json_schema" do
      duck = Struct.new(:schema) { def to_json_schema = schema }.new(json_schema)
      schema = described_class.new(duck)

      expect(schema.json_schema).to eq(json_schema)
      expect(schema.validate({ "label" => "ok" })).to be_empty
      expect(schema.validate({ "label" => 1 })).not_to be_empty
      expect(schema.build({ "label" => "ok" }, squished: true).label).to eq("ok")
    end

    it "sends a duck-typed schema to the provider as a strict schema" do
      duck = Struct.new(:schema) { def to_json_schema = schema }.new(json_schema)

      expect(described_class.new(duck).llm_schema).to include("schema" => json_schema, "strict" => true)
    end

    it "enforces strict mode on a duck-typed schema that sets strict: false" do
      duck = Struct.new(:schema) { def to_json_schema = schema }.new(json_schema.merge("strict" => false))

      expect { described_class.new(duck) }.to raise_error(Squishling::ConfigurationError, /strict/)
    end

    it "rejects a value that is neither a Hash, a Schematist schema, nor responds to to_json_schema" do
      ["a string", 42, nil, Object.new, [json_schema]].each do |raw|
        expect { described_class.new(raw) }
          .to raise_error(Squishling::ConfigurationError, /Unsupported output_schema: #{Regexp.escape(raw.inspect)}/)
      end
    end

    it "rejects a class that is not a Schematist::Schema" do
      expect { described_class.new(String) }
        .to raise_error(Squishling::ConfigurationError, /String is not a Schematist::Schema/)
    end

    it "surfaces an unsupported schema when a squished method runs, before any request is made" do
      klass = Class.new do
        include Squishling

        purpose "Classify."
        output_schema Object.new
      end
      chats = stub_llm({ "label" => "ok" })

      expect { klass.call(text: "x") }.to raise_error(Squishling::ConfigurationError, /Unsupported output_schema/)
      expect(chats).to be_empty
    end
  end

  describe "$ref resolution when typing results" do
    def build(schema, data)
      described_class.new(schema).build(data, squished: true)
    end

    let(:address) do
      {
        "type" => "object",
        "properties" => { "city" => { "type" => "string" } },
        "required" => ["city"],
        "additionalProperties" => false
      }
    end

    it "types a property that references a local definition" do
      schema = {
        "type" => "object",
        "properties" => { "home" => { "$ref" => "#/$defs/address" } },
        "required" => ["home"],
        "additionalProperties" => false,
        "$defs" => { "address" => address }
      }

      result = build(schema, { "home" => { "city" => "Oslo" } })

      expect(result.home).to be_a(Data)
      expect(result.home.city).to eq("Oslo")
      expect(result.home).to be_squished
      expect(result.to_h).to eq(home: { city: "Oslo" })
    end

    it "types arrays of referenced objects and optional references" do
      schema = {
        "type" => "object",
        "properties" => {
          "stops" => { "type" => "array", "items" => { "$ref" => "#/$defs/address" } },
          "billing" => { "anyOf" => [{ "$ref" => "#/$defs/address" }, { "type" => "null" }] }
        },
        "required" => %w[stops billing],
        "additionalProperties" => false,
        "$defs" => { "address" => address }
      }

      result = build(schema, { "stops" => [{ "city" => "Oslo" }, { "city" => "Bergen" }], "billing" => nil })

      expect(result.stops.map(&:city)).to eq(%w[Oslo Bergen])
      expect(result.billing).to be_nil
      expect(build(schema, { "stops" => [], "billing" => { "city" => "Rome" } }).billing.city).to eq("Rome")
    end

    it "resolves a ref through nested definition paths" do
      schema = {
        "type" => "object",
        "properties" => { "home" => { "$ref" => "#/definitions/geo/address" } },
        "required" => ["home"],
        "additionalProperties" => false,
        "definitions" => { "geo" => { "address" => address } }
      }

      expect(build(schema, { "home" => { "city" => "Oslo" } }).home.city).to eq("Oslo")
    end

    it "types a recursive schema to any depth with one shared class" do
      node = {
        "type" => "object",
        "properties" => {
          "name" => { "type" => "string" },
          "children" => { "type" => "array", "items" => { "$ref" => "#/$defs/node" } }
        },
        "required" => %w[name children],
        "additionalProperties" => false
      }
      schema = node.merge("$defs" => { "node" => node })
      data = { "name" => "a", "children" => [{ "name" => "b", "children" => [{ "name" => "c", "children" => [] }] }] }

      result = build(schema, data)

      expect(result.children.first.children.first.name).to eq("c")
      expect(result.children.first.class).to eq(result.children.first.children.first.class)
      expect(result.to_h).to eq(
        name: "a", children: [{ name: "b", children: [{ name: "c", children: [] }] }]
      )
    end

    it "fails at build for a non-local or dangling ref, rather than leaving values untyped" do
      %w[https://example.com/address.json #/$defs/nope].each do |ref|
        schema = {
          "type" => "object",
          "properties" => { "home" => { "$ref" => ref } },
          "required" => ["home"],
          "additionalProperties" => false
        }

        expect { build(schema, { "home" => { "city" => "Oslo" } }) }
          .to raise_error(Squishling::ConfigurationError, /\$ref that can't be resolved/)
      end
    end

    it "still validates referenced objects against the full schema" do
      schema = {
        "type" => "object",
        "properties" => { "home" => { "$ref" => "#/$defs/address" } },
        "required" => ["home"],
        "additionalProperties" => false,
        "$defs" => { "address" => address }
      }
      validation = described_class.new(schema)

      expect(validation.validate({ "home" => { "city" => "Oslo" } })).to be_empty
      expect(validation.validate({ "home" => { "city" => 7 } })).not_to be_empty
      expect(validation.validate({ "home" => {} })).not_to be_empty
    end
  end
end
