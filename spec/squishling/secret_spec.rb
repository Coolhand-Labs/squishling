# frozen_string_literal: true

require "pp"
require "yaml"

RSpec.describe "Squishling::Secret" do
  let(:secret_class) { Squishling.const_get(:Secret, false) }
  let(:secret) { secret_class.new("sk-SECRETKEY") }

  def holder_of(value)
    Class.new do
      def initialize(value) = (@value = value)
    end.new(value)
  end

  it "gives the value back only through #reveal" do
    expect(secret.reveal).to eq("sk-SECRETKEY")
  end

  it "is frozen and keeps the value out of its instance variables" do
    expect(secret).to be_frozen
    expect(secret.instance_variables.map { |name| secret.instance_variable_get(name) }.grep(String)).to be_empty
  end

  it "shows [REDACTED] for inspect, to_s, interpolation and pp" do
    expect([secret.inspect, secret.to_s, "key #{secret}", secret.pretty_inspect.strip])
      .to eq(["[REDACTED]", "[REDACTED]", "key [REDACTED]", "[REDACTED]"])
  end

  it "shows [REDACTED] in to_yaml, alone and inside another object" do
    expect(secret.to_yaml).to include("[REDACTED]")
    expect(secret.to_yaml).not_to include("SECRETKEY")
    expect(holder_of(secret).to_yaml).not_to include("SECRETKEY")
  end

  it "shows [REDACTED] for as_json and JSON, alone and inside a document" do
    expect(secret.as_json).to eq("[REDACTED]")
    expect(JSON.generate([secret, { "k" => secret }])).to eq('["[REDACTED]",{"k":"[REDACTED]"}]')
  end

  it "refuses Marshal with a fixed TypeError" do
    expect { Marshal.dump(secret) }.to raise_error(TypeError, /can't be dumped/)
    expect { Marshal.dump(holder_of(secret)) }.to raise_error(TypeError) { |error|
      expect(error.message).not_to include("SECRETKEY")
    }
  end
end
