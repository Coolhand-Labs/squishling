# frozen_string_literal: true

# Shared harness for the live examples: resolves the provider API key, configures RubyLLM and
# Squishling for one small model, and runs a set of scenarios that exercise the gem end to end.

require "optparse"
require "bundler/setup"
require "squishling"

module LiveHarness
  Scenario = Struct.new(:name, :block)

  module_function

  # Key resolution order: --api-key flag, then the provider's env var, else exit 1.
  # params: generation params the model supports, applied to every scenario.
  # rejected_params: params the model is known to reject, which must fail loudly.
  def run(script:, provider:, env_var:, default_model:, params:, rejected_params:)
    options = parse_options(script, default_model)
    api_key = options[:api_key] || ENV.fetch(env_var, nil)
    if api_key.nil? || api_key.strip.empty?
      warn "#{script}: no API key. Pass --api-key KEY or set #{env_var}."
      exit 1
    end

    RubyLLM.configure { |config| config.public_send(:"#{provider}_api_key=", api_key) }
    Squishling.configure do |config|
      config.default_model = options[:model]
      config.default_provider = provider
      config.max_retries = 1
      config.default_params = params
    end
    @rejected_params = rejected_params

    puts "Squishling live examples: #{provider} / #{options[:model]} / params #{params.inspect}\n\n"
    failures = SCENARIOS.count { |scenario| !run_scenario(scenario) }
    puts "\n#{SCENARIOS.size - failures}/#{SCENARIOS.size} passed"
    exit(failures.zero? ? 0 : 1)
  end

  def parse_options(script, default_model)
    options = { model: default_model }
    OptionParser.new do |opts|
      opts.banner = "Usage: bundle exec ruby examples/#{script} [--api-key KEY] [--model MODEL]"
      opts.on("--api-key KEY", "Provider API key (overrides the env var)") { |key| options[:api_key] = key }
      opts.on("--model MODEL", "Model to test (default: #{default_model})") { |model| options[:model] = model }
    end.parse!
    options
  end

  def run_scenario(scenario)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    detail = scenario.block.call
    puts "  ✓ #{scenario.name} (#{elapsed(started)}s)#{" — #{detail}" if detail.is_a?(String)}"
    true
  rescue StandardError => e
    puts "  ✗ #{scenario.name} (#{elapsed(started)}s)\n      #{e.class}: #{e.message}"
    false
  end

  def elapsed(started)
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2)
  end

  def rejected_params = @rejected_params

  def check(condition, message)
    raise message unless condition
  end

  # Routes "hardened" vendors to Ruby and everything else to the LLM.
  class InvoiceParser
    include Squishling

    instructions "Extract the invoice number, line items and total from the vendor's raw invoice text."
    output_schema do
      string :invoice_number
      number :total
      array :line_items do
        object do
          string :description
          integer :quantity
          number :unit_price
        end
      end
    end
    squish_when { |vendor:, **| vendor != "acme" }

    def call(vendor:, text:)
      result(invoice_number: "#{vendor.upcase}-#{text}", total: 0, line_items: [])
    end
  end

  # Unimplemented method with per-method instructions/schema and opt-in instance context.
  class TicketTriager
    include Squishling

    squish_context :customer_tier
    squish :triage, instructions: "Triage the support ticket. Enterprise customers with outages are high priority." do
      string :priority, enum: %w[low medium high]
      string :team, enum: %w[billing platform support]
    end

    def initialize(customer_tier:, api_client: Object.new)
      @customer_tier = customer_tier
      @api_client = api_client
    end

    def triage(ticket_text) = raise(NotImplementedError)
  end

  # Raw JSON Schema hash, strict-compliant.
  class SentimentClassifier
    include Squishling

    instructions "Classify the sentiment of the review."
    output_schema(
      type: "object",
      properties: {
        sentiment: { type: "string", enum: %w[positive negative neutral] },
        confidence: { type: "number" }
      },
      required: %w[sentiment confidence],
      additionalProperties: false
    )
  end

  # `optional` fields: null means "not mentioned", [] means "explicitly none".
  class VisitSummarizer
    include Squishling

    instructions <<~TEXT
      Summarize the clinic note. Use null for anything the note doesn't mention, and an empty list when
      the note explicitly says there are none.
    TEXT
    output_schema do
      array :symptoms, of: :string
      optional :vitals do
        object do
          integer :heart_rate
        end
      end
      optional :medications do
        array of: :string
      end
      optional :allergies do
        array of: :string
      end
    end
  end

  # Ruby parses "Name <email>"; anything else is handed to the LLM from the rescue, with the parse error as
  # context and this class's own source appended to the instructions.
  class ContactParser
    include Squishling

    instructions "Extract the contact's name and email address."
    append_instructions "The Ruby parser for well-formed contacts, for context on the expected output:", self
    output_schema do
      string :name
      string :email
    end

    def call(text:)
      match = text.match(/\A(?<name>[^<]+?)\s*<(?<email>[^>]+)>\z/)
      raise ArgumentError, "expected \"Name <email>\", got #{text.inspect}" unless match

      result(name: match[:name], email: match[:email])
    rescue ArgumentError => e
      squish!(
        append_instructions: "The Ruby parser failed on this input; the error is in the context.",
        context: { parse_error: e }
      )
    end
  end

  # Fallback that must never run for a setup mistake.
  class Echo
    include Squishling

    instructions "Reply with one word."
    output_schema { string :word }
    squish_fallback { |_error, **| { word: "fallback" } }
  end

  INVOICE_TEXT = <<~TEXT
    GLOBEX CORP — Invoice #INV-2041
    3 x Widget @ $10.00
    2 x Gadget @ $25.00
    TOTAL DUE: $80.00
  TEXT

  SCENARIOS = [
    Scenario.new("routing predicate sends unhardened input to the LLM", lambda {
      result = InvoiceParser.call(vendor: "globex", text: INVOICE_TEXT)
      check(result.squished?, "expected an LLM result")
      check(result.invoice_number.include?("2041"), "invoice_number was #{result.invoice_number.inspect}")
      check((result.total - 80).abs < 0.01, "total was #{result.total.inspect}")
      check(result.line_items.size == 2, "expected 2 line items, got #{result.line_items.size}")
      check(result.line_items.first.is_a?(Data), "line items should be typed Data objects")
      "#{result.invoice_number}, total #{result.total}"
    }),
    Scenario.new("routing predicate keeps hardened input in Ruby", lambda {
      result = InvoiceParser.call(vendor: "acme", text: "7")
      check(!result.squished?, "expected the deterministic path")
      check(result.invoice_number == "ACME-7", "invoice_number was #{result.invoice_number.inspect}")
    }),
    Scenario.new("both paths return the same result class", lambda {
      llm = InvoiceParser.call(vendor: "globex", text: INVOICE_TEXT)
      ruby = InvoiceParser.call(vendor: "acme", text: "7")
      check(llm.instance_of?(ruby.class), "#{llm.class} vs #{ruby.class}")
    }),
    Scenario.new("NotImplementedError falls back to the LLM with squish_context", lambda {
      result = TicketTriager.new(customer_tier: "enterprise").triage("Production API is completely down for all users!")
      check(result.priority == "high", "priority was #{result.priority.inspect}")
      check(result.team == "platform", "team was #{result.team.inspect}")
      "#{result.priority} / #{result.team}"
    }),
    Scenario.new("squish! keeps well-formed input in Ruby", lambda {
      result = ContactParser.call(text: "Ada Lovelace <ada@example.com>")
      check(!result.squished?, "expected the deterministic path")
      check(result.email == "ada@example.com", "email was #{result.email.inspect}")
    }),
    Scenario.new("squish! hands a failed Ruby parse to the LLM with the class source appended", lambda {
      result = ContactParser.call(text: "You can reach Ada Lovelace at ada (at) example (dot) com.")
      check(result.squished?, "expected an LLM result")
      check(result.email == "ada@example.com", "email was #{result.email.inspect}")
      check(result.name.include?("Lovelace"), "name was #{result.name.inspect}")
      "#{result.name} <#{result.email}>"
    }),
    Scenario.new("raw JSON Schema hash output", lambda {
      result = SentimentClassifier.call(review: "Absolutely love it — best purchase I've made all year!")
      check(result.sentiment == "positive", "sentiment was #{result.sentiment.inspect}")
      check(result.confidence.is_a?(Numeric), "confidence was #{result.confidence.inspect}")
      "#{result.sentiment} (#{result.confidence})"
    }),
    Scenario.new("optional fields keep null (not mentioned) distinct from [] (none)", lambda {
      result = VisitSummarizer.call(note: "Patient reports a cough and fever. Heart rate 88. Takes no medications.")
      check(result.symptoms.size >= 2, "symptoms were #{result.symptoms.inspect}")
      check(result.vitals.is_a?(Data) && result.vitals.heart_rate == 88, "vitals were #{result.vitals.inspect}")
      check(result.medications == [], "medications were #{result.medications.inspect}")
      check(result.allergies.nil?, "allergies were #{result.allergies.inspect}")
      "medications=[] allergies=nil"
    }),
    Scenario.new("params the model rejects raise ConfigurationError, not the fallback", lambda {
      klass = Class.new(Echo) { squishling params: LiveHarness.rejected_params }
      begin
        result = klass.call
      rescue Squishling::ConfigurationError => e
        check(e.message.include?("provider rejected the request"), "unexpected message: #{e.message}")
        next "rejected #{LiveHarness.rejected_params.inspect}"
      end
      raise "expected ConfigurationError, got #{result.to_h.inspect}"
    })
  ].freeze
end
