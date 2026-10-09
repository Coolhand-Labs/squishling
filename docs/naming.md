# Naming and collisions

`include Squishling` adds a small set of methods to your class. This page lists them and explains what happens
when one of those names is already taken.

## What Squishling adds

| Where | Names |
|---|---|
| Class-level DSL | `squishling`, `purpose`, `append_to_purpose`, `output_schema`, `squish`, `squish_when`, `squish_fallback`, `squish_validate`, `squish_context`, `squished_methods`, `call`, and the `squishling_*` readers |
| Instance | `squishling_result`, `squish!`, and `result` (an alias for `squishling_result`) |

Methods your class defines itself always win over these, whether you define them before or after the `include`.
Only methods your class *inherits* can be shadowed.

## Inherited collisions raise

If a parent class or an earlier-included module already defines a class-level DSL method, `squish!` or
`squishling_result`, `include Squishling` raises `Squishling::ConfigurationError` listing every clash and where
it comes from:

```
ConfigurationError: MyApp inherits methods that Squishling would override: MyApp.call (from Sinatra::Base's
class methods). Include Squishling in a plain Ruby class instead ...
```

This is deliberate. Squishling's modules sit ahead of inherited ones, so without the check
`Sinatra::Base.call(env)` (the Rack entry point), or any `call` or `purpose` your parent class defines, would be
replaced silently. Put Squishling in a plain Ruby class and have your framework object call it instead.

## `result` is skipped when taken

`result` is a convenience for `squishling_result`. If the class already has a `result` (its own or inherited), it is
left alone and Squishling does not add the alias. Use `squishling_result(...)` instead; it is always available.

**ActiveRecord caveat.** Column readers are generated lazily, so Squishling can't see a `result` column when you
include it. Its `result` would then shadow the column reader. On a model with a `result` column, call
`squishling_result` (or keep Squishling out of the model and use a plain class).

## Not a collision

ActiveSupport adds `String#squish` and `String#squish!`. Those live on `String`; Squishling's `squish!` lives on
your class, so they never meet. They only look alike when reading code in a Rails app.
