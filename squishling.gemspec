# frozen_string_literal: true

require_relative "lib/squishling/version"

Gem::Specification.new do |spec|
  spec.name = "squishling"
  spec.version = Squishling::VERSION
  spec.authors = ["Michael Carroll"]
  spec.email = ["mc@coolhandlabs.com"]

  spec.summary = "Elastic Ruby classes that run as deterministic code or as a structured LLM call via RubyLLM."
  spec.description = "Declare any Ruby class a squishling: give it instructions and a strict output schema, and " \
                     "its methods can bypass their Ruby implementation to run their inputs through an LLM " \
                     "(OpenAI, Anthropic Claude, Google Gemini, and any provider RubyLLM supports), returning " \
                     "schema-validated, typed results. Route per input with a predicate, fall back to the LLM " \
                     "for unimplemented methods, and harden high-volume paths into code as the economics justify it."
  spec.homepage = "https://github.com/Coolhand-Labs/squishling"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/Coolhand-Labs/squishling"
  spec.metadata["changelog_uri"] = "https://github.com/Coolhand-Labs/squishling/blob/main/CHANGELOG.md"
  spec.metadata["documentation_uri"] = "https://github.com/Coolhand-Labs/squishling/tree/main/docs"

  # Ship only what's tracked in git, minus development-only files.
  dev_files = %w[AGENTS.md CLAUDE.md]
  dev_prefixes = %w[bin/ test/ spec/ features/ examples/ .git .claude .idea .rubocop .simplecov .rspec Gemfile]
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      File.expand_path(f) == __FILE__ || dev_files.include?(f) || f.start_with?(*dev_prefixes)
    end
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "json_schemer", "~> 2.0"
  spec.add_dependency "ruby_llm", "~> 2.0"
  spec.add_dependency "schematist", "~> 1.1"

  spec.metadata["rubygems_mfa_required"] = "true"
end
