# Verifying squished classes

Most mistakes in a squished class fail when the class loads (a bad `escalation:`, `params:`, `harness:` or `squawk:`
raises `ConfigurationError` as the declaration runs). The output schema and its typed result are built on the first
call, and the keywords your `include_when:` and `squish_when` procs take are only used when a call is routed. So
Squishling keeps a list of the classes that include it and can check them all without making a request, for example
in CI.

## `Squishling.verify` and `verify!`

```ruby
report = Squishling.verify            # every squished class
report.ok?                            # => false
puts report
# Squishling found 2 problems:
#   Triage#route: escalation step "claude-haiku-4-5" include_when: requires tier:, which is not an input of the method
#   Invoice#call: invalid data member: total=

Squishling.verify!                    # raises Squishling::VerificationError (a ConfigurationError) naming every problem
Squishling.verify(Triage, Invoice)    # just these classes
```

`verify` returns a `Squishling::Verification::Report` (`ok?`, `size`, `problems`, `to_s`). Each problem has a
`label` and a `message`. `verify!` returns the report when it is clean and otherwise raises
`Squishling::VerificationError`, which has `report` and `problems`. Every problem is listed, not just the first.

For each squished method (inherited ones too, with the subclass's settings) it checks:

- **The output schema:** that it builds (and is strict), is valid JSON Schema, and produces a typed result, so a
  property name that can't be a result member (`total=`), an object with `properties` but no `type: "object"`, or a
  `$ref` that doesn't resolve within the schema (a remote URI is never fetched; a missing `$defs` entry) is reported.
  A method with no output schema or no purpose is reported, because its LLM path would raise. The default `call`
  method is skipped when you don't implement or configure it.
- **What the layers resolve to:** the escalation, generation params and `squawk` that the method, its class and
  `Squishling.config` add up to.
- **The harness:** that it is still registered (not removed or replaced since the class declared it), and that a
  `type: :judgment` judge has an adapter that supports judgments.
- **Keywords:** that each `include_when:` and the `squish_when` block can be called with the method's inputs as keywords
  (`instance_exec(**inputs, &proc)`): no required keyword that isn't an input, and no input a lambda (or a proc that names
  keywords) can't take. Add `**` to accept any. A method that takes `**` or has no implementation can receive any
  keyword, so nothing is reported for it. `squish_fallback` and `squish_validate` are called with the inputs too, but
  aren't checked.
- **The adapter** (once): that `config.adapter`, or RubyLLM's, can be built.

A problem in an inherited method is reported once for each subclass, since each is checked with its own settings.

Nothing is sent to a provider, and your own code (the Ruby implementation, `squish_when`, the procs) is not run.

## Only loaded classes are checked

The list holds the classes that have been loaded. In Rails, load everything first:

```ruby
Rails.application.eager_load!
Squishling.verify!
```

The list holds its classes weakly, so it doesn't keep classes alive across code reloads, and a named class whose
constant now holds a different object (replaced by a reload but not yet collected) is left out. Anonymous classes are
included. `Squishling.squished_classes` returns the list.

## In CI

**Rake.** In Rails the `squishling:verify` task is added for you and eager loads the app first. Elsewhere, load it in your
`Rakefile`:

```ruby
load "squishling/tasks/squishling.rake"
```

`bundle exec rake squishling:verify` prints the report and exits non-zero when there are problems. Load your classes
before the task runs (an `:environment` task, if you have one, is invoked first). The Railtie adds the task in Rails
when Squishling is required after Rails (as Bundler does), so a Rails app needn't load the file itself.

**RSpec.** `require "squishling/rspec"` adds a matcher whose failure message is the report:

```ruby
require "squishling/rspec"

RSpec.describe "squished classes" do
  before(:all) { Rails.application.eager_load! }

  it { expect(Squishling).to be_squishling_valid }
  it { expect(InvoiceParser).to be_squishling_valid }   # or just one class, or an Array of them
end
```
