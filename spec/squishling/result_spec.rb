# frozen_string_literal: true

RSpec.describe Squishling::Result do
  def schema_with(*names)
    {
      "type" => "object",
      "properties" => names.to_h { |name| [name.to_s, { "type" => "string" }] },
      "required" => names.map(&:to_s),
      "additionalProperties" => false
    }
  end

  describe "reserved property names" do
    described_class::RESERVED_NAMES.each do |name|
      it "rejects `#{name}` when the schema is built" do
        expect { Squishling::Schema.new(schema_with(name)) }
          .to raise_error(Squishling::ConfigurationError, /result needs: #{Regexp.escape(name.to_s)}\./)
      end
    end

    it "lists every clashing name in one message" do
      expect { Squishling::Schema.new(schema_with(:ok, :class, :hash, :members)) }
        .to raise_error(Squishling::ConfigurationError, /: class, hash, members\./)
    end

    it "rejects a clash in a nested object" do
      nested = schema_with(:outer).merge("properties" => { "outer" => schema_with(:to_h) })

      expect { Squishling::Schema.new(nested) }.to raise_error(Squishling::ConfigurationError, /: to_h\./)
    end

    it "rejects a clash in an array's item objects" do
      rows = { "type" => "array", "items" => schema_with(:class) }
      list = schema_with(:rows).merge("properties" => { "rows" => rows })

      expect { Squishling::Schema.new(list) }.to raise_error(Squishling::ConfigurationError, /: class\./)
    end

    it "keeps names that merely resemble inherited methods" do
      names = %i[method display format type test freeze hash_value squished]
      result = Squishling::Schema.new(schema_with(*names)).build(names.to_h { |n| [n.to_s, n.to_s] }, squished: true)

      expect(names.map { |n| result[n] }).to eq(names.map(&:to_s))
      expect(result.method).to eq("method")
    end

    it "raises from a squished method before any request is made" do
      klass = Class.new do
        include Squishling

        purpose "Classify."
        output_schema({ "type" => "object", "properties" => { "class" => { "type" => "string" } },
                        "required" => ["class"], "additionalProperties" => false })
      end
      chats = stub_llm({ "class" => "a" })

      expect { klass.call(text: "x") }.to raise_error(Squishling::ConfigurationError, /: class\./)
      expect(chats).to be_empty
    end

    # A field named after any Object, Kernel, or Data method must either be reserved or leave the result's
    # contract intact; this catches methods a newer Ruby adds.
    it "reserves every inherited method name that would break the result" do
      inherited = (Data.public_instance_methods + Data.private_instance_methods +
                   Object.public_instance_methods + Kernel.private_instance_methods).uniq
      names = inherited.grep(/\A[a-z_][a-z_0-9]*\??\z/) - described_class::RESERVED_NAMES

      broken = names.reject { |name| contract_intact?(name) }

      expect(broken).to be_empty, "add to Result::RESERVED_NAMES: #{broken.join(', ')}"
    end

    def contract_intact?(name)
      klass = Data.define(name).include(Squishling::Result::Instance)
      value = "v"
      result = klass.new(squishling_squished: true, name => value)
      # Kernel's own method, so a field named `instance_of?` doesn't hide the check
      typed = ->(object) { Kernel.instance_method(:instance_of?).bind_call(object, klass) }
      twin = klass.new(squishling_squished: true, name => value)

      [
        result.squished? == true, result[name] == value, result.to_h == { name => value },
        typed.call(result), result.members == [name], result.inspect.is_a?(String),
        result.is_a?(klass), result.to_s.is_a?(String), result == twin, result.eql?(twin),
        result.hash.is_a?(Integer),
        result.send(:to_h) == { name => value }, typed.call(result.dup), typed.call(result.with(name => "w")),
        result.deconstruct_keys(nil) == { name => value }
      ].all?
    rescue StandardError
      false
    end
  end
end
