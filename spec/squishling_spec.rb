# frozen_string_literal: true

RSpec.describe Squishling do
  let(:invoice_parser) do
    Class.new do
      include Squishling

      instructions "Extract invoice fields."
      output_schema do
        string :invoice_number
        number :total
        array :line_items do
          object do
            string :description
            number :amount
          end
        end
      end
      squish_when { |client_name:, **| client_name != "acme" }

      def call(client_name:, data:)
        result(invoice_number: "ACME-#{data}", total: 10, line_items: [{ description: client_name, amount: 10 }])
      end
    end
  end

  let(:llm_invoice) do
    { "invoice_number" => "INV-42", "total" => 1250.0,
      "line_items" => [{ "description" => "Widgets", "amount" => 1250.0 }] }
  end

  describe "routing" do
    it "runs the deterministic path when the predicate is falsy" do
      chats = stub_llm

      result = invoice_parser.call(client_name: "acme", data: "7")

      expect(result.invoice_number).to eq("ACME-7")
      expect(result.squished?).to be(false)
      expect(chats).to be_empty
    end

    it "sends the inputs to the LLM when the predicate is truthy" do
      chats = stub_llm(llm_invoice)

      result = invoice_parser.call(client_name: "globex", data: "raw,csv")

      expect(result.squished?).to be(true)
      expect(result.total).to eq(1250.0)
      expect(JSON.parse(chats.first.messages.first))
        .to eq("arguments" => { "client_name" => "globex", "data" => "raw,csv" })
      expect(chats.first.instructions).to start_with("Extract invoice fields.")
    end

    it "falls back to the LLM when the method raises NotImplementedError" do
      klass = Class.new do
        include Squishling

        instructions "Summarize."
        output_schema { string :summary }

        def call(text) = raise(NotImplementedError)
      end
      chats = stub_llm({ "summary" => "short" })

      expect(klass.call("long text").summary).to eq("short")
      expect(JSON.parse(chats.first.messages.first)).to eq("arguments" => { "text" => "long text" })
    end

    it "falls back to the LLM when the method is not defined at all" do
      klass = Class.new do
        include Squishling

        instructions "Summarize."
        output_schema { string :summary }
      end
      stub_llm({ "summary" => "short" })

      expect(klass.call(text: "x").summary).to eq("short")
    end

    it "evaluates the predicate against the instance" do
      klass = Class.new do
        include Squishling

        instructions "Echo."
        output_schema { string :value }
        squish_when { @elastic }

        def initialize(elastic) = @elastic = elastic
        def call = { value: "ruby" }
      end
      stub_llm({ "value" => "llm" })

      expect(klass.new(false).call.value).to eq("ruby")
      expect(klass.new(true).call.value).to eq("llm")
    end
  end

  describe "squish for named methods" do
    let(:triager) do
      Class.new do
        include Squishling

        instructions "Default instructions."
        squish_context :customer_tier, :product

        squish :triage, instructions: "Triage the ticket.", model: "triage-model" do
          string :priority, enum: %w[low med high]
          string :team
        end

        def initialize(customer_tier:, product:, db: nil)
          @customer_tier = customer_tier
          @product = product
          @db = db
        end

        attr_reader :customer_tier

        def triage(ticket_text, urgent: false) = raise(NotImplementedError)
      end
    end

    it "uses per-method instructions, schema and model, and sends opt-in context" do
      chats = stub_llm({ "priority" => "high", "team" => "platform" })

      result = triager.new(customer_tier: "enterprise", product: "API", db: Object.new).triage("down!", urgent: true)

      expect(result.to_h).to eq(priority: "high", team: "platform")
      chat = chats.first
      expect(chat.model).to eq("triage-model")
      expect(chat.instructions).to start_with("Triage the ticket.")
      expect(JSON.parse(chat.messages.first)).to eq(
        "arguments" => { "ticket_text" => "down!", "urgent" => true },
        "context" => { "customer_tier" => "enterprise", "product" => "API" }
      )
    end

    it "wraps methods regardless of whether squish comes before or after def" do
      klass = Class.new do
        include Squishling

        def shout(word) = { word: word.upcase }
        squish :shout, instructions: "Shout." do
          string :word
        end
      end
      stub_llm

      expect(klass.new.shout("hi").word).to eq("HI")
    end
  end

  describe "output schemas" do
    it "accepts a raw JSON Schema hash" do
      klass = Class.new do
        include Squishling

        instructions "Classify."
        output_schema({ type: "object", properties: { label: { type: "string" } }, required: ["label"],
                        additionalProperties: false })
      end
      chats = stub_llm({ "label" => "spam" })

      expect(klass.call(text: "buy now").label).to eq("spam")
      expect(chats.first.schema).to include("strict" => true)
      expect(chats.first.schema["schema"]).to include("type" => "object")
    end

    it "always requests strict output from RubyLLM" do
      payload = Squishling::Schema.new(RubyLLM::Schema.create { string :label }).llm_schema

      expect(payload["strict"]).to be(true)
      expect(payload["schema"]).not_to have_key("strict")
      expect(RubyLLM::Chat.allocate.send(:normalize_schema_payload, payload)).to include(strict: true)
    end

    it "rejects non-strict schemas" do
      raw = { type: "object", properties: { label: { type: "string" } } }
      dsl = RubyLLM::Schema.create do
        strict false
        string :label
      end

      [raw.merge(strict: false), { name: "x", schema: raw, strict: false }, dsl].each do |schema|
        expect { Squishling::Schema.new(schema) }
          .to raise_error(Squishling::ConfigurationError, /only supports strict/)
      end
    end

    it "rejects a non-strict class schema when the method is invoked" do
      expect do
        Class.new do
          include Squishling

          output_schema({ type: "object", properties: {}, strict: false })
          instructions "x"
        end.call
      end.to raise_error(Squishling::ConfigurationError, /only supports strict/)
    end

    it "accepts explicitly strict schemas, top-level and nested" do
      raw = { type: "object", properties: { label: { type: "string" } }, required: ["label"] }

      [raw.merge(strict: true), { name: "x", schema: raw.merge(strict: true) }].each do |schema|
        payload = Squishling::Schema.new(schema).llm_schema
        expect(payload["strict"]).to be(true)
        expect(payload["schema"]).not_to have_key("strict")
      end
    end

    it "lets a top-level strict flag win over one inside the schema, as RubyLLM does" do
      raw = { type: "object", properties: {}, strict: false }

      expect { Squishling::Schema.new({ name: "x", schema: raw, strict: true }) }.not_to raise_error
    end

    it "preserves the name and description of a wrapped schema" do
      schema = Class.new(RubyLLM::Schema) do
        description "A label"
        string :label
      end
      payload = Squishling::Schema.new(schema).llm_schema

      expect(payload).to include("description" => "A label", "strict" => true)
      expect(payload).to have_key("name")
    end

    it "omits name and description for a bare hash so RubyLLM supplies its defaults" do
      payload = Squishling::Schema.new({ type: "object", properties: {} }).llm_schema

      expect(payload.keys).to contain_exactly("schema", "strict")
      expect(RubyLLM::Chat.allocate.send(:normalize_schema_payload, payload)).to include(name: "response")
    end

    it "validates data without the strict keyword in the JSON Schema" do
      schema = Squishling::Schema.new(RubyLLM::Schema.create { string :label })

      expect(schema.json_schema).not_to have_key("strict")
      expect(schema.validate({ "label" => "ok" })).to be_empty
      expect(schema.validate({ "label" => 1 })).not_to be_empty
    end

    it "accepts a RubyLLM::Schema subclass" do
      schema = Class.new(RubyLLM::Schema) { string :label }
      klass = Class.new do
        include Squishling

        instructions "Classify."
        output_schema schema
      end
      stub_llm({ "label" => "ham" })

      expect(klass.call(text: "hello").label).to eq("ham")
    end

    it "parses JSON string responses" do
      stub_llm(JSON.generate(llm_invoice))

      expect(invoice_parser.call(client_name: "globex", data: "").invoice_number).to eq("INV-42")
    end
  end

  describe "typed results" do
    it "builds nested Data objects with hash access and deep to_h" do
      stub_llm(llm_invoice)

      result = invoice_parser.call(client_name: "globex", data: "")

      expect(result).to be_a(Data)
      expect(result.line_items.first.description).to eq("Widgets")
      expect(result[:total]).to eq(1250.0)
      expect(result.to_h).to eq(invoice_number: "INV-42", total: 1250.0,
        line_items: [{ description: "Widgets", amount: 1250.0 }])
    end

    it "returns the same result class from both paths" do
      stub_llm(llm_invoice)

      deterministic = invoice_parser.call(client_name: "acme", data: "1")
      elastic = invoice_parser.call(client_name: "globex", data: "")

      expect(deterministic.class).to equal(elastic.class)
      expect(deterministic.line_items.first.class).to equal(elastic.line_items.first.class)
    end

    it "coerces and validates plain hashes returned by the deterministic path" do
      klass = Class.new do
        include Squishling

        instructions "x"
        output_schema { integer :count }

        def call(valid:) = valid ? { count: 3 } : { count: "three" }
      end

      expect(klass.call(valid: true).count).to eq(3)
      expect { klass.call(valid: false) }.to raise_error(Squishling::InvalidOutputError, /Deterministic/)
    end
  end

  describe "invalid LLM output" do
    it "retries with the validation errors, then succeeds" do
      chats = stub_llm({ "invoice_number" => 5 }, llm_invoice)

      expect(invoice_parser.call(client_name: "globex", data: "").total).to eq(1250.0)
      expect(chats.first.messages.last).to include("did not match the required schema")
    end

    it "raises after exhausting retries" do
      Squishling.configure { |c| c.max_retries = 2 }
      chats = stub_llm("not json", { "total" => "x" }, { "total" => "y" })

      expect { invoice_parser.call(client_name: "globex", data: "") }
        .to raise_error(Squishling::InvalidOutputError) { |e| expect(e.raw).to eq("total" => "y") }
      expect(chats.first.messages.size).to eq(3)
    end
  end

  describe "model resolution" do
    def model_used(klass)
      chats = stub_llm({ "value" => "v" })
      klass.call
      chats.first.model
    end

    let(:base) do
      Class.new do
        include Squishling

        instructions "x"
        output_schema { string :value }
      end
    end

    it "uses the universal default model" do
      Squishling.configure { |c| c.default_model = "universal" }
      expect(model_used(base)).to eq("universal")
    end

    it "prefers the class model over the universal default" do
      Squishling.configure { |c| c.default_model = "universal" }
      base.squishling(model: "class-model")
      expect(model_used(base)).to eq("class-model")
    end

    it "defers to RubyLLM's default when none is set" do
      expect(model_used(base)).to be_nil
    end
  end

  describe "provider resolution" do
    def chat_for(klass, method = :call)
      chats = stub_llm({ "value" => "v" })
      klass.new.public_send(method)
      chats.first
    end

    let(:base) do
      Class.new do
        include Squishling

        instructions "x"
        output_schema { string :value }
      end
    end

    it "assumes a model exists when it's missing from RubyLLM's registry and a provider is given" do
      base.squishling(model: "gpt-6-luna", provider: :openai)
      chat = chat_for(base)

      expect(chat.model).to eq("gpt-6-luna")
      expect(chat.options).to eq(provider: :openai, assume_model_exists: true)
    end

    it "keeps registry lookups for known models" do
      base.squishling(model: "claude-haiku-4-5", provider: :anthropic)

      expect(chat_for(base).options).to eq(provider: :anthropic)
    end

    it "sends no provider when none is declared" do
      base.squishling(model: "claude-haiku-4-5")

      expect(chat_for(base).options).to eq({})
    end

    it "uses the configured default provider with the default model" do
      Squishling.configure do |c|
        c.default_model = "gpt-6-luna"
        c.default_provider = :openai
      end

      expect(chat_for(base).options).to eq(provider: :openai, assume_model_exists: true)
    end

    it "keeps a provider paired with the model declared at the same level" do
      base.squishling(model: "gpt-6-luna", provider: :openai)
      base.squish(:quick, model: "claude-haiku-4-5") { string :value }
      chat = chat_for(base, :quick)

      expect(chat.model).to eq("claude-haiku-4-5")
      expect(chat.options).to eq({})
    end

    it "accepts a per-method provider" do
      base.squish(:luna, model: "gpt-6-luna", provider: :openai) { string :value }

      expect(chat_for(base, :luna).options).to eq(provider: :openai, assume_model_exists: true)
    end

    it "inherits the class provider in subclasses" do
      base.squishling(model: "gpt-6-luna", provider: :openai)

      expect(chat_for(Class.new(base)).options).to include(provider: :openai)
    end
  end

  describe "inheritance" do
    let(:parent) do
      Class.new do
        include Squishling

        squishling model: "parent-model", instructions: "Parent."
        output_schema { string :value }
        squish_when { |mode:| mode == :llm }

        def call(**) = { value: "parent" }
      end
    end

    it "inherits settings and routes subclass overrides" do
      child = Class.new(parent) do
        def call(**) = { value: "child" }
      end
      chats = stub_llm({ "value" => "llm" })

      expect(child.call(mode: :ruby).value).to eq("child")
      expect(child.call(mode: :llm).value).to eq("llm")
      expect(chats.first.model).to eq("parent-model")
    end

    it "routes once when a subclass override calls super" do
      child = Class.new(parent) do
        def call(mode:) = super.to_h.merge(value: "child+#{super.value}")
      end
      chats = stub_llm

      expect(child.call(mode: :ruby).value).to eq("child+parent")
      expect(chats).to be_empty
    end
  end

  describe "configuration errors" do
    it "requires instructions for the elastic path" do
      klass = Class.new do
        include Squishling

        output_schema { string :value }
      end
      stub_llm

      expect { klass.call }.to raise_error(Squishling::ConfigurationError, /instructions/)
    end

    it "rejects inclusion into a module" do
      expect { Module.new { include Squishling } }.to raise_error(Squishling::ConfigurationError)
    end
  end
end
