# frozen_string_literal: true

# Live tests: Squishling's Coolhand observer against a small provider model and a real coolhand gem (0.9.0+).
# Run: bundle exec ruby examples/coolhand_example.rb [--provider openai|anthropic] [--api-key KEY] [--model MODEL]
# Key: --api-key, else OPENAI_API_KEY (ANTHROPIC_API_KEY for --provider anthropic), else exits 1.
#
# The provider requests are real, so the coolhand gem captures them as it would in your app. Its log requests go
# to a throwaway server on 127.0.0.1 instead of coolhandlabs.com, so nothing needs a Coolhand account, and each
# scenario can read back exactly what Coolhand was sent, `declared` identity included.

require_relative "support/live_harness"
require "socket"

begin
  require "coolhand"
rescue LoadError
  warn "coolhand_example.rb: the coolhand gem is missing. Add `gem \"coolhand\", \"~> 0.9\"` to your bundle."
  exit 1
end
unless Coolhand.respond_to?(:with_context)
  warn "coolhand_example.rb: coolhand #{Coolhand::VERSION} has no Coolhand.with_context; it needs 0.9.0 or newer."
  exit 1
end

module CoolhandExample
  # Stands in for coolhandlabs.com: records each POSTed llm_request_log and answers 201. Plain sockets, so it
  # needs no gem.
  class Capture
    LOGS_PATH = %r{\A/api/v2/llm_request_logs\z}

    def initialize
      @server = TCPServer.new("127.0.0.1", 0)
      @logs = []
      @lock = Mutex.new
      @thread = Thread.new { serve }
    end

    def base_url = "http://127.0.0.1:#{@server.addr[1]}/api"

    # What Coolhand has sent since the last #clear, as parsed `llm_request_log` Hashes.
    def logs = @lock.synchronize { @logs.dup }

    def clear = @lock.synchronize { @logs.clear }

    def stop
      @thread.kill
      @server.close
    end

    private

    def serve
      loop { Thread.new(@server.accept) { |client| handle(client) } }
    rescue IOError, Errno::EBADF
      nil # the server was closed
    end

    def handle(client)
      verb, path = client.gets.to_s.split
      length = 0
      while (line = client.gets) && line != "\r\n"
        length = line.split(":", 2).last.to_i if line.downcase.start_with?("content-length:")
      end
      body = client.read(length).to_s
      record(body) if verb == "POST" && LOGS_PATH.match?(path)
      client.write("HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: 2\r\n" \
                   "Connection: close\r\n\r\n{}")
    ensure
      client.close
    end

    def record(body)
      log = JSON.parse(body)["llm_request_log"]
      @lock.synchronize { @logs << log } if log
    rescue JSON::ParserError => e
      warn "coolhand_example.rb: Coolhand sent a log that isn't JSON (#{e.message})"
    end
  end

  PROVIDERS = {
    "openai" => { env_var: "OPENAI_API_KEY", default_model: "gpt-6-luna", params: { thinking: { effort: :low } } },
    "anthropic" => { env_var: "ANTHROPIC_API_KEY", default_model: "claude-haiku-4-5-20251001",
                     params: { temperature: 0 } }
  }.freeze

  REVIEW = "Absolutely love it — best purchase I've made all year!"

  class << self
    attr_reader :capture

    def provider
      name = take_provider_option || "openai"
      PROVIDERS.key?(name) ? name : abort("coolhand_example.rb: --provider must be #{PROVIDERS.keys.join(' or ')}")
    end

    # Removes --provider NAME (or --provider=NAME) from ARGV, which LiveHarness would reject, and returns NAME.
    def take_provider_option
      inline = ARGV.index { |arg| arg.start_with?("--provider=") }
      return ARGV.delete_at(inline).delete_prefix("--provider=") if inline

      index = ARGV.index("--provider")
      ARGV.slice!(index, 2).last if index
    end

    # Points Coolhand at the capture server, with synchronous logging so a log has arrived once the call returns,
    # and runs the scenarios inside it.
    def around
      @capture = Capture.new
      Coolhand.configure do |config|
        config.api_key = "example-key"
        config.base_url = capture.base_url
        config.silent = true
        config.async_logging = false
      end
      yield
    ensure
      capture&.stop
    end

    # A named subclass, so the workload key reads "CoolhandExample::Reviews#call" rather than an anonymous class.
    def define(name, **declaration)
      klass = Class.new(LiveHarness::SentimentClassifier)
      CoolhandExample.const_set(name, klass)
      klass.squishling(provider: Squishling.config.default_provider, **declaration)
      klass
    end

    def model = Squishling.config.default_model_path.first[:model]

    # The `declared` identity of every request Coolhand captured since the last scenario.
    def declared
      Coolhand.flush
      capture.logs.filter_map { |log| log["declared"] }
    end

    def templates = declared.map { |identity| identity.dig("template", "key") }
  end
end

CoolhandExample::SCENARIOS = [
  LiveHarness::Scenario.new("a call is declared to Coolhand with no observer configured", lambda do
    CoolhandExample.capture.clear
    CoolhandExample.define("Auto", model: CoolhandExample.model).call(review: CoolhandExample::REVIEW)

    identity = CoolhandExample.declared.first
    LiveHarness.check(identity, "Coolhand captured no declared identity")
    LiveHarness.check(identity["reporter"] == "squishling", "reporter was #{identity['reporter'].inspect}")
    LiveHarness.check(identity["workload"]["key"] == "CoolhandExample::Auto#call",
      "workload was #{identity['workload']}")
    LiveHarness.check(identity["workload"]["description"].include?("sentiment"), "description lacked the purpose")
    LiveHarness.check(identity.dig("template", "key") == "CoolhandExample::Auto#call/squish:L1",
      "template was #{identity['template']}")
    identity.dig("template", "name")
  end),
  LiveHarness::Scenario.new("an escalation declares each level as its own template", lambda do
    CoolhandExample.capture.clear
    model = CoolhandExample.model
    klass = CoolhandExample.define("Escalating", escalation: [{ model:, params: { max_output_tokens: 4096 } },
                                                              { model:, params: { max_output_tokens: 8192 } }])
    # The first answer is always rejected, so the call escalates to the second level.
    seen = 0
    klass.squish_validate { |_result, **| "try again" if (seen += 1) == 1 }
    klass.call(review: CoolhandExample::REVIEW)

    expected = %w[CoolhandExample::Escalating#call/squish:L1 CoolhandExample::Escalating#call/squish:L2]
    LiveHarness.check(CoolhandExample.templates == expected, "templates were #{CoolhandExample.templates.inspect}")
    "L1, L2"
  end),
  LiveHarness::Scenario.new("squishsum declares each sample, from the worker threads that make the requests", lambda do
    CoolhandExample.capture.clear
    klass = CoolhandExample.define("Sampled", model: CoolhandExample.model,
      harness: { type: :squishsum, compare: ->(first, second, **) { first.sentiment == second.sentiment } })
    klass.call(review: CoolhandExample::REVIEW)

    templates = CoolhandExample.templates.sort
    expected = %w[CoolhandExample::Sampled#call/sample:a CoolhandExample::Sampled#call/sample:b]
    LiveHarness.check(templates == expected, "templates were #{templates.inspect}")
    "sample:a, sample:b"
  end),
  LiveHarness::Scenario.new("a judge is declared as its own template", lambda do
    CoolhandExample.capture.clear
    model = CoolhandExample.model
    provider = Squishling.config.default_provider
    # compare: never agrees, so the judge always runs.
    klass = CoolhandExample.define("Judged", model:,
      harness: { type: :judged_squishsum, compare: ->(*) { false }, judge: { model:, provider: } })
    klass.call(review: CoolhandExample::REVIEW)

    templates = CoolhandExample.templates.sort
    expected = %w[CoolhandExample::Judged#call/judge CoolhandExample::Judged#call/sample:a
                  CoolhandExample::Judged#call/sample:b]
    LiveHarness.check(templates == expected, "templates were #{templates.inspect}")
    "sample:a, sample:b, judge"
  end),
  LiveHarness::Scenario.new("observer = false stops declaring, and Coolhand still captures the call", lambda do
    CoolhandExample.capture.clear
    Squishling.configure { |config| config.observer = false }
    CoolhandExample.define("Silenced", model: CoolhandExample.model).call(review: CoolhandExample::REVIEW)
    Coolhand.flush

    logs = CoolhandExample.capture.logs
    LiveHarness.check(logs.size == 1, "expected the one captured request, got #{logs.size}")
    LiveHarness.check(logs.first["declared"].nil?, "expected no declared identity, got #{logs.first['declared']}")
  ensure
    Squishling.configure { |config| config.observer = nil }
  end),
  LiveHarness::Scenario.new("a custom observer gets the request's token usage, and replaces Coolhand's", lambda do
    CoolhandExample.capture.clear
    usages = []
    observer = Object.new
    observer.define_singleton_method(:around) { |_call, &block| usages << block.call }
    Squishling.configure { |config| config.observer = observer }
    CoolhandExample.define("Metered", model: CoolhandExample.model).call(review: CoolhandExample::REVIEW)

    usage = usages.first
    LiveHarness.check(usages.size == 1, "expected 1 usage, got #{usages.size}")
    LiveHarness.check(usage.input_tokens.to_i.positive? && usage.output_tokens.to_i.positive?,
      "usage was #{usage.inspect}")
    LiveHarness.check(usage.model.is_a?(String), "model was #{usage.model.inspect}")
    LiveHarness.check(CoolhandExample.capture.logs.size == 1, "expected the one captured request")
    LiveHarness.check(CoolhandExample.declared.empty?, "Coolhand declarations should come from its own observer only")
    "in=#{usage.input_tokens} out=#{usage.output_tokens} #{usage.model}"
  ensure
    Squishling.configure { |config| config.observer = nil }
  end)
].freeze

provider = CoolhandExample.provider
LiveHarness.run(
  script: File.basename(__FILE__),
  provider: provider.to_sym,
  scenarios: CoolhandExample::SCENARIOS,
  around: ->(&scenarios) { CoolhandExample.around(&scenarios) },
  **CoolhandExample::PROVIDERS.fetch(provider)
)
