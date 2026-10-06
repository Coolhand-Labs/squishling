---
name: prep-release
description: |
  Runs an entire release event for this gem: triages every open PR into a
  quality/risk-rated merge recommendation, waits for the user's sign-off,
  squash-merges the chosen PRs, writes the release's changelog and version
  bump plus a whole-package security red-team on its own release branch,
  validates that branch with the full test suite and live-key example
  apps, then opens a single release-prep PR for the user's final review.
  Never merges that PR, tags, or publishes. Use when the user types
  /prep-release, asks to "prep a release", "cut a release", "release
  checklist", or wants the open PRs triaged and merged into a release.
user_invocable: true
version: 1.0.0
---

# Prep Release

Five phases, run in order. This is a whole-release audit, not a
single-branch review — Phase 3 onward operates on the whole `lib/` tree and
everything merged since the last tag, not just one diff. For an iterative
diff-scoped review during normal development, use `/loop-review` instead;
this skill is for the release event itself.

Per `AGENTS.md`, feature/fix branches never touch `CHANGELOG.md` or
`lib/squishling/version.rb` — this skill is the only place those get written.
If a chosen PR's diff does touch either file, treat it as a normal part of
that PR's diff (don't strip it), but don't let it change how Phase 3 writes
its own entry — Phase 3's changelog write-up is authoritative regardless of
what an individual PR's diff already contains.

## Phase 1: Survey open PRs, recommend a release set

1. `gh pr list --state open --json number,title,author,isDraft,mergeable,mergeStateStatus,statusCheckRollup,additions,deletions,changedFiles,body,headRefName`.
2. For each PR, pull `gh pr diff <n>` and `gh pr checks <n>` and rate two
   independent axes:
   - **Quality** (High/Medium/Low): does the diff include spec coverage
     proportional to the `lib/` change, is the code consistent with this
     repo's style/conventions, does the PR description read as complete
     work rather than a stub or "WIP, not ready" note.
   - **Risk** (High/Medium/Low): does it touch the routing core or the
     elastic path (`lib/squishling/router.rb`, `wrapper.rb`,
     `definition.rb`, `invoker.rb`), schema/result handling
     (`schema.rb`, `result.rb`), the error taxonomy (`errors.rb`), or the
     gemspec's runtime dependencies — weight those higher regardless of
     size, since they decide what data reaches the LLM and whether both
     paths keep returning the same validated type; failing CI checks or a
     non-clean `mergeable` state also push risk up; an isolated additive
     feature or docs-only change is lower risk.
3. Present one table: PR number, title, quality, risk, CI status,
   mergeable state, and a one-line recommendation (include / exclude /
   needs work before it can be considered). Call out anything that looks
   unfinished — draft, a WIP-sounding title, failing checks, an empty or
   placeholder description, visible `TODO`/`FIXME` in the diff — as
   "exclude, not ready" rather than rating it neutrally.
4. Stop here and ask the user which PRs to include in this release. This
   is the one planned decision point in the whole skill — do not merge,
   write changelog entries, or touch `version.rb` until the user answers.
   (Phase 2 step 3 below has its own unplanned-error stop for an unclean
   working tree; that's an abort on unexpected state, not a second
   decision point like this one.)

## Phase 2: Merge the chosen PRs

Process the user's chosen PRs one at a time, not as a batch:

1. Before each merge, re-check that PR's `mergeable`/`mergeStateStatus`
   (`gh pr view <n> --json mergeable,mergeStateStatus`) — an earlier merge
   in this same run can newly conflict a later one. If a chosen PR now
   conflicts, skip it, note it in the running list as "skipped — needs
   rebase," and continue with the rest. Don't resolve conflicts on someone
   else's branch unilaterally.
2. `gh pr merge <n> --squash --delete-branch` for each surviving PR.
3. After each merge, sync local `main` before evaluating the next PR.
   First check `git status --porcelain` — if it's not empty, stop and
   surface it to the user rather than discarding unknown local state;
   otherwise `git fetch origin main && git checkout main && git reset
   --hard origin/main` is safe, since it only overwrites a working tree
   already confirmed clean with the just-fetched remote `main`.

Keep a running list of what actually merged vs. what got skipped — Phase 5
reports both.

## Phase 3: Build the release branch — docs/changelog/version + red-team

Create `release/vX.Y.Z` off the freshly synced `main` (version number per
step 5 below) and do all of the following as commits on that branch —
never on `main` directly.

### Docs, changelog, version

1. Find the last release tag: `git describe --tags --abbrev=0`. **If there
   is no tag yet, this is the first release**: everything on `main` is
   unreleased, the changelog entry describes the gem's initial feature
   set (under `## [X.Y.Z]`, grouped `### Added`), and the version in
   `lib/squishling/version.rb` ships as-is rather than being bumped —
   it has never been published.
2. Diff **everything since that tag** on the now-updated `main` —
   `git log <last-tag>..HEAD --oneline` and `git diff <last-tag>..HEAD -- lib/`
   — not just the PRs this run merged in Phase 2. `main` can carry
   unreleased changes Phase 2 never touched (a hotfix committed directly,
   a PR merged manually outside this skill, or a prior `/prep-release` run
   that merged PRs but was interrupted before finishing this phase); all
   of those still need a changelog entry, so treat this diff, not Phase
   2's merge list, as the source of truth for what's covered.
3. For each change, check it's reflected in:
   - `CHANGELOG.md` — one entry per change under `[Unreleased]` (or a new
     version heading), in Keep a Changelog format matching this repo's
     existing entries — plain-English migration notes for anything
     behavior-affecting. Attribute each entry to its PR number where one
     exists: check Phase 2's merge list first, then fall back to the
     squash-merge commit message (`git log --grep`, which carries the PR
     number in its title) for anything not merged in this run. If a
     change genuinely has no discoverable PR (a direct commit to `main`),
     write the entry without one rather than skipping it.
   - `README.md` / `docs/*.md` — any new config option, DSL method, or
     behavior change needs the relevant section updated. Follow this
     repo's docs philosophy from `AGENTS.md`: the README stays a scannable
     landing page (basic config snippet and quick start only); anything
     needing more than one code block belongs in `docs/`.
4. **Clean, don't just append.** Look for docs that are now stale,
   contradictory, or redundant given the accumulated changes since the
   last tag — consolidate/rewrite rather than layering a new paragraph on
   top of an outdated one. Remove docs for anything removed from the gem.
5. **Bump the version.** Since `AGENTS.md` forbids per-PR bumps, this
   should always be needed (except on the first release, per step 1) —
   but check `lib/squishling/version.rb` against the last tag first as a
   defensive sanity check in case something bumped it out of band.
   Determine the SemVer bump this repo's convention implies (patch = fix,
   minor = backward-compatible addition or breaking change while
   pre-1.0), write it to `lib/squishling/version.rb`, turn the
   `[Unreleased]` CHANGELOG heading into `## [X.Y.Z] - <today's date>`
   (keeping an empty `## [Unreleased]` above it), and run `bundle install`
   so `Gemfile.lock`'s `squishling (X.Y.Z)` line matches.

### Red-team

Adversarially review the entire `lib/` tree (not just what merged in Phase
2) for security issues. This gem sends application data to third-party LLM
providers and turns their output into typed Ruby objects that host apps
act on, so hunt specifically for:

- **Data egress**: what exactly leaves the process in `Invoker#payload`?
  Only method arguments and explicitly named `squish_context` values may
  be sent. Flag anything that could serialize instance variables
  wholesale, API clients, credentials, or objects whose `to_s`/`to_h`
  leaks more than intended (`Schema.jsonify` falls back to `to_s` for
  arbitrary objects).
- **Credential/secret leakage**: can an API key, or sensitive input data,
  end up in an exception message (`LLMError`, `ConfigurationError`,
  `InvalidOutputError#message`/`#raw`) or a `config.logger` line? Provider
  error messages are interpolated into ours — check what RubyLLM puts in
  them.
- **Untrusted model output**: LLM output is attacker-influenceable (prompt
  injection through user-supplied inputs). Confirm it is only ever
  `JSON.parse`d (no `Marshal`, `YAML.load`, `create_additions`, `eval`,
  `constantize`/`const_get` on returned strings), always schema-validated
  before typing, and that result building can't be steered into calling
  arbitrary methods (e.g. property names colliding with `Data`/`Object`
  methods like `class`, `send`, `hash`).
- **Validation bypass / fail-open**: is there any path where output
  reaches the caller without passing `json_schemer` validation — a
  retry branch, the code-fence stripper, a `squish_fallback` return, a
  non-object root schema, `anyOf` unions left untyped? Does a
  `strict: false` schema slip through any accepted schema form?
- **Params passthrough**: generation params are deep-merged into the
  provider request last. Confirm `Params::RESERVED_KEYS` still covers
  every top-level key Squishling/RubyLLM set for each provider in the
  installed `ruby_llm` version (check each provider's `render_payload`),
  so params can't replace the model, conversation, or strict output
  format, and that a provider 400 still surfaces as `ConfigurationError`
  rather than being absorbed by `squish_fallback`.
- **ReDoS**: any regex applied to model output or user-influenced input
  (`Invoker#strip_code_fence`) — check for catastrophic backtracking
  shapes (nested quantifiers, overlapping alternation) on large inputs.
- **Thread/fiber safety**: routing frames are fiber-local; `Schema::CACHE`
  is mutex-guarded; DSL settings live in class-level ivars. Look for
  unsynchronized shared mutable state a concurrent request could race on,
  and for memoization (`@result_class`, `@squishling_fields`) that could
  publish a half-built object.
- **Model/provider resolution**: `assume_model_exists` is set only when a
  provider is named and the model is missing from RubyLLM's registry —
  can a config combination route a request to an unintended provider or
  model (e.g. a per-method model inheriting a class-level provider)?

For each finding, report file, line, a concrete failure scenario, and
severity. Apply safe, mechanical, low-risk fixes directly, as commits on
`release/vX.Y.Z` (e.g. redacting a value from an error message, tightening
a regex). Flag but do not silently apply anything that's a
behavior/architecture decision (e.g. changing what context is sent to the
LLM, changing retry or fallback semantics, changing the error taxonomy) —
surface these to the user for a decision, the same "hand it to a human"
rule `/loop-review` uses for stuck findings.

## Phase 4: Validate the release branch

1. Run `bundle exec rake` (`rspec` then `rubocop`, per the `Rakefile`) on
   `release/vX.Y.Z`. All specs must pass and RuboCop must report zero
   offenses before continuing — a release doesn't ship on a red build. If
   either fails, stop here and report the failures; fixing genuine bugs
   takes priority over the rest of this phase and Phase 5.

   Then judge coverage on quality, not just the SimpleCov percentage the
   rake run reports (written to `coverage/`): find the gaps and weight by
   risk (an uncovered error-handling or security-check branch matters more
   than an uncovered `attr_reader`); audit existing tests for
   meaningfulness, not just count (flag tests that only assert a stub
   returns what it was stubbed to return, missing negative/error-path
   cases, missing domain edge cases); recommend specific specs for the
   highest-risk gaps, named by `file:describe/context` — don't add tests
   purely to move the percentage.

2. If Phase 4.1 is green, run every `*_example.rb` script in `examples/`
   against live provider keys: `bundle exec ruby examples/<name>.rb` for
   each (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`). Unlike some Coolhand
   repos, these scripts **exit 1** when their key is missing (message
   `no API key. Pass --api-key KEY or set …`) rather than skipping —
   record that case as "not run (no key)" and tell the user, since this
   release check needs both providers. Record pass/not-run/fail per
   script, including each script's scenario tally. A script that exits
   non-zero with a key present is a real failure and should be
   investigated before continuing to Phase 5 — it means this release
   would ship with a broken elastic path for that provider.

## Phase 5: Open the release-prep PR, report everything

1. Push `release/vX.Y.Z` and `gh pr create` (e.g. "chore: release
   vX.Y.Z") targeting `main`. This PR is the user's final checkpoint
   before the changelog/version/red-team commit lands — never merge it,
   tag it, or run `rake release`/`gem push` yourself.
2. Report one consolidated summary covering the whole run:
   - Phase 1's PR table and which PRs the user chose.
   - Phase 2's outcome: which PRs merged, which were skipped for new
     conflicts (and need a rebase before the next release).
   - The release-prep PR link, the version bump and why.
   - Coverage-quality gaps plus recommended specs.
   - Docs updated.
   - Red-team findings split into fixed vs. flagged-for-decision.
   - Phase 4's regression test/lint result and the example-app run
     results (pass/skip/fail per script).

## Safety

- Bumping `lib/squishling/version.rb`, finalizing the CHANGELOG heading, and
  running `bundle install` for the lockfile are all in scope and don't
  need a stop-and-ask — they're mechanical, reversible, and gated on Phase
  4 already being green before the PR opens.
- Squash-merging PRs the user explicitly chose in Phase 1, and pushing the
  `release/vX.Y.Z` branch to open its own PR, are both in scope.
- Never push a commit directly to `main`. All release-branch work lands on
  `main` only via the Phase 5 PR, which the user reviews and merges
  themselves.
- Never create or push a git tag, never run `rake release` or `gem push`,
  and never merge the Phase 5 PR yourself. Tagging and publishing are the
  user's action once they've reviewed and merged this skill's PR, not
  something this skill does.

## Rationalizations to resist

- *"This PR's CI is green and the diff is small, I don't need to look at
  the actual diff."* CI passing doesn't rule out unfinished work — a
  small, green diff can still be a stub that leaves a feature half-built.
  Read the diff.
- *"The diff since the last tag is small, I'll skip the red-team."* Small
  diffs can still sit on top of latent issues in code nobody's touched
  recently — that's exactly what "whole package, not just the diff" means.
- *"Tests pass, so coverage is fine."* Passing tests and meaningful
  coverage are different questions. A red build blocks release; a green
  build with hollow tests doesn't guarantee anything.
- *"Docs are close enough, I'll skip the cleanup pass."* Accumulated
  changes since the last tag are exactly when docs drift from behavior —
  this phase exists because per-PR doc updates miss the cross-cutting
  view.
- *"The example apps are just smoke tests, I'll skip them since specs
  passed."* Specs stub `RubyLLM.chat`; the example apps are the only step
  in this skill that sends a real strict schema to a real provider and
  parses what comes back — whether a provider accepts a schema shape, or
  returns `null` vs `[]` correctly, is a different failure mode than a
  unit test can catch.
