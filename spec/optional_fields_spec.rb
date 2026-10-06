# frozen_string_literal: true

RSpec.describe "Squishling optional (nullable) fields" do
  let(:klass) do
    Class.new do
      include Squishling

      instructions "Summarize the visit."
      output_schema do
        array :symptoms, of: :string
        optional :vitals do
          object do
            integer :bpm
          end
        end
        optional :medications do
          array do
            object do
              string :name
            end
          end
        end
      end
    end
  end

  def visit(vitals: nil, medications: nil, symptoms: [])
    { "symptoms" => symptoms, "vitals" => vitals, "medications" => medications }
  end

  it "keeps every key required in the strict schema" do
    schema = Squishling::Schema.for(klass.output_schema).json_schema

    expect(schema["required"]).to contain_exactly("symptoms", "vitals", "medications")
    expect(schema["properties"]["vitals"]["anyOf"]).to include({ "type" => "null" })
  end

  it "types a present optional object and list of objects" do
    stub_llm(visit(vitals: { "bpm" => 72 }, medications: [{ "name" => "ibuprofen" }]))

    result = klass.call(notes: "x")

    expect(result.vitals).to be_a(Data)
    expect(result.vitals.bpm).to eq(72)
    expect(result.medications.first).to be_a(Data)
    expect(result.medications.first.name).to eq("ibuprofen")
  end

  it "keeps null (not provided) distinct from an empty array (none)" do
    stub_llm(visit(medications: []))

    result = klass.call(notes: "x")

    expect(result.vitals).to be_nil
    expect(result.medications).to eq([])
    expect(result.symptoms).to eq([])
    expect(result.to_h).to eq(symptoms: [], vitals: nil, medications: [])
  end

  it "still rejects an omitted key" do
    stub_llm({ "symptoms" => [] }, { "symptoms" => [] })

    expect { klass.call(notes: "x") }.to raise_error(Squishling::InvalidOutputError, /vitals/)
  end

  it "rejects null for a non-optional field" do
    stub_llm(visit(symptoms: nil), visit(symptoms: nil))

    expect { klass.call(notes: "x") }.to raise_error(Squishling::InvalidOutputError)
  end

  it "types nullable fields from a raw JSON Schema type array" do
    raw = Class.new do
      include Squishling

      instructions "x"
      output_schema(
        type: "object",
        properties: {
          items: { type: %w[array null], items: { type: "object", properties: { n: { type: "integer" } },
                                                  required: ["n"], additionalProperties: false } }
        },
        required: ["items"], additionalProperties: false
      )
    end
    stub_llm({ "items" => [{ "n" => 1 }] }, { "items" => nil })

    expect(raw.call.items.first.n).to eq(1)
    expect(raw.call.items).to be_nil
  end

  it "leaves unions with several non-null branches untyped" do
    union = Class.new do
      include Squishling

      instructions "x"
      output_schema do
        any_of :value do
          object { string :a }
          object { string :b }
        end
      end
    end
    stub_llm({ "value" => { "a" => "x" } })

    expect(union.call.value).to eq(a: "x")
  end

  it "builds the same types on the deterministic path" do
    det = Class.new(klass) do
      def call = { symptoms: ["cough"], vitals: { bpm: 60 }, medications: nil }
    end

    result = det.call

    expect(result.vitals.bpm).to eq(60)
    expect(result.medications).to be_nil
  end
end
