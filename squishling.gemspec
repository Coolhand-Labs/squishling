# frozen_string_literal: true

require_relative "lib/squishling/version"

Gem::Specification.new do |spec|
  spec.name = "squishling"
  spec.version = Squishling::VERSION
  spec.authors = ["Michael Carroll"]
  spec.email = ["michael@carroll.io"]

  spec.summary = "Elastic Ruby classes that can run as deterministic code or as an LLM call."
  spec.description = <<~DESC
    Declare any class as a squishling: give it instructions and an output schema, and its methods can
    bypass their Ruby implementation and run their inputs through an LLM (via RubyLLM) instead,
    returning validated, typed results. Harden hot paths into deterministic code as the economics justify it.
  DESC
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "json_schemer", "~> 2.0"
  spec.add_dependency "ruby_llm", "~> 1.16"
  spec.add_dependency "ruby_llm-schema", "~> 0.4"
end
