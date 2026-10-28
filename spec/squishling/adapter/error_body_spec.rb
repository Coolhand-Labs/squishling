# frozen_string_literal: true

RSpec.describe Squishling::Adapter::ErrorBody do
  describe ".read" do
    it "reads an OpenAI-style error from a Hash or a JSON String" do
      body = { "error" => { "message" => "no", "type" => "invalid_request_error", "code" => "bad",
                            "param" => "top_p" } }

      [body, JSON.generate(body)].each do |form|
        expect(described_class.read(form)).to eq(status: "invalid_request_error", code: "bad", param: "top_p")
      end
    end

    it "reads a Gemini-style error wrapped in an Array, preferring status over type" do
      body = [{ "error" => { "code" => 400, "status" => "INVALID_ARGUMENT", "type" => "other" } }]

      expect(described_class.read(body)).to eq(status: "INVALID_ARGUMENT", code: "400", param: nil)
    end

    it "drops a code that only repeats the HTTP status" do
      body = { "error" => { "code" => 400, "status" => "INVALID_ARGUMENT" } }

      expect(described_class.read(body, http_status: "400")).to eq(status: "INVALID_ARGUMENT", code: nil, param: nil)
    end

    it "accepts only short plain tokens" do
      body = { "error" => { "status" => "has spaces", "code" => "x" * 65, "type" => "sk-proj-abc\nline",
                            "param" => "a b" } }

      expect(described_class.read(body)).to eq(status: nil, code: nil, param: nil)
    end

    it "refuses a status or code longer than a word, but allows a long field path" do
      body = { "error" => { "status" => "A" * 41, "code" => "sk-#{'a' * 40}", "param" => "messages[0].content" } }

      expect(described_class.read(body)).to eq(status: nil, code: nil, param: "messages[0].content")
    end

    it "refuses a hyphenated status or code, so an API key echoed there is never repeated" do
      body = { "error" => { "status" => "sk-proj-abc123", "code" => "sk-ant-api03-abc",
                            "type" => "invalid_request_error" } }

      expect(described_class.read(body)).to eq(status: "invalid_request_error", code: nil, param: nil)
    end

    it "ignores a Hash with Symbol keys" do
      expect(described_class.read({ error: { status: "INVALID_ARGUMENT" } })).to eq(status: nil, code: nil, param: nil)
    end

    ["not json", "null", "5", "[]", "[1]", '{"error":"text"}', '{"error":[]}', "", nil, 5].each do |body|
      it "returns nothing for #{body.inspect}" do
        expect(described_class.read(body)).to eq(status: nil, code: nil, param: nil)
      end
    end
  end

  describe ".error" do
    it "returns the error Hash, or nil" do
      expect(described_class.error('{"error":{"message":"m"}}')).to eq("message" => "m")
      expect(described_class.error('{"error":"m"}')).to be_nil
    end
  end
end
