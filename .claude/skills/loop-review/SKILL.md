---
name: loop-review
description: |
  Iteratively runs code review against the current diff, applies fixes, and
  re-reviews until a round comes back clean (or a safety cap is hit). Use
  when the user types /loop-review, asks to "loop the review", "review
  until clean", "keep reviewing and fixing until nothing's left", or wants
  a self-healing code review cycle instead of a single one-shot pass.
user_invocable: true
version: 1.0.0
---

# Loop Review

This skill reviews the working diff, applies fixes, and re-reviews until a
round finds nothing new or a safety cap is reached. Use it after a merge,
a large diff, or whenever a single review pass isn't enough to converge on
a clean state.

Each round's review is done by spawning a fresh review Agent with the
inlined prompt below (see "The round loop") rather than invoking
`/code-review`: `/code-review` has `disable-model-invocation: true`, so it
can only be run directly by the user, never programmatically via the
`Skill` tool by an agent. Do not attempt to invoke it — spawn the Agent
instead.

## Scope

Default scope is the diff against the repo's base branch, working tree
included: `git diff origin/main` (substitute `origin/main` with whatever
base branch applies). Do NOT use the triple-dot form
(`git diff origin/main...HEAD`) as the default — it only sees committed
history and silently returns empty on a branch whose work is still
uncommitted, which would make round 1 rubber-stamp "LGTM" on real,
unreviewed changes, and would make every later round re-review the
pre-fix diff forever since this skill only edits the working tree (see
Safety) and never commits. If the arguments this skill was invoked with
name a path or a narrower scope, review only that instead of the full
diff.

Also run `git status --short` before round 1. Brand-new untracked files
(`??`) don't show up in `git diff origin/main` at all, which would let a
new file skip review entirely. If there are any, run
`git add -N <path>...` (intent-to-add — stages the path as an empty file
without staging its content, so it appears as a full addition in the diff
without changing what would actually be committed) before the first
review round. This is the one index mutation the loop makes; it's
intentional, left in place for the user to commit alongside everything
else (or undo with `git reset -- <path>` if not wanted) — see Safety.

This skill is deliberately diff-scoped. For a whole-package audit before a
release (full-codebase security red-team, docs review, everything since
the last tag) use `/prep-release` instead.

The invocation's arguments may also contain:
- An effort level describing how thorough each round's review Agent
  should be (`low`/`medium`/`high`/`max`). Default: `medium`. Pass this
  through as plain text in the review prompt (e.g. "Effort: EFFORT") —
  there's no tool-level effort parameter for a spawned Agent.
- A round cap override, e.g. `--max-rounds 3`. Default: 5.

## The round loop

Repeat the following cycle up to the round cap:

1. **Review.** Spawn a review Agent (via the `Agent` tool) against the
   current scope. Give it: the scope command from above, the round
   number, the effort level, the full "Review criteria" checklist below
   (including the severity taxonomy), and the list of fixes already
   applied in prior rounds (so it doesn't re-flag them). Ask it to return
   a numbered list of issues, each tagged with its severity bucket and
   prefixed in the form `1. [CRITICAL] file:line — problem — fix`, or the
   exact string `LGTM: No issues found.` if there are none. Its response
   should end with a line `TOKENS_USED: <number>` — its own best estimate
   of tokens consumed that round, approximate rather than metered, based
   on whatever visibility it has into its own context/conversation size.
   Because the response now ends with that line, the LGTM check is: the
   *first line* of the response is exactly `LGTM: No issues found.`, not
   the whole response. Also record `date +%s` immediately before spawning
   this round's review Agent — the start of this round's timing window
   for the CSV log (see Wrap-up).
2. **Clean round (first line `LGTM: No issues found.`) → run the Verify
   step (step 4) once** — a clean-looking diff can still have a broken
   test suite the reviewer Agent never ran. If Verify passes, converged:
   move to Wrap-up. If Verify fails, it's not actually converged: treat
   the failures as a `[CRITICAL]` finding and go to step 3, then run
   another round (subject to the round cap) to confirm the fix.
3. **Findings found → give every one of them a disposition.** For each
   finding, either fix it (using Edit, Write, and Bash tools to apply the
   fix directly in this session) or reject it with a one-line reason
   (false positive / out of scope / disagree with the call) — no silent
   skipping. Verify failures should essentially never be rejected; a
   reviewer-agent finding can be, when the reason genuinely holds up.
   Record, per round: what was found (with severity), what was fixed,
   and what was rejected (with its reason) — see the log format below —
   so the next round's reviewer prompt can list fixes as already-applied
   and the final report can show fixed/rejected counts.
4. **Verify.** Run `bundle exec rake` (`rspec` then `rubocop`, per the
   `Rakefile`) after applying this round's fixes. If it fails, that
   failure is itself a `[CRITICAL]` finding for the next round — don't
   move on with a red build. A fix can pass its own narrow spec while
   breaking something elsewhere, and the next round's reviewer Agent
   isn't checking test/lint output, only the diff. If a fix round changed
   something outside this repo's usual toolchain, discover the right
   command instead of assuming. Record `date +%s` again once Verify
   completes — the end of this round's timing window for the CSV log
   (see Wrap-up).
5. **Findings found and fixed** → do not declare victory yet. Run another
   round to confirm the fixes didn't introduce a regression and that
   nothing was missed.
6. **No-progress detection**: if two consecutive rounds return the same
   non-empty set of findings, fixing isn't resolving them mechanically
   (likely a design/architecture call that needs a human). Stop looping,
   list the stuck findings, and hand them to the user instead of retrying
   forever.
7. **Safety cap**: if the round cap is reached without converging or
   getting stuck, stop and report the remaining findings — don't loop
   silently past the cap.

Each round's fixes should stay reviewable: don't squash multiple rounds
into one silent edit. Note per-round changes in the final summary so the
user can inspect them with `git diff`.

Maintain a running log across rounds:

```
=== Round 1 ===
Reviewer found N issues (X critical, Y nice-to-have, Z nitpick):
  1. [CRITICAL] file:line — problem — fix
  2. [NICE-TO-HAVE] file:line — problem — fix
  ...
Fixed (F):
  - [what was done to resolve issue 1]
  - [what was done to resolve issue 2]
Rejected (R):
  - [issue N] — [one-line reason]
Tokens used (reviewer estimate): NNNN

=== Round 2 ===
...

=== RESULT ===
[CLEAN after N rounds] or [STOPPED at round cap — N issues remain] or
[STOPPED — no progress after N rounds, M issues remain]
```

## Review criteria

Give the review Agent spawned in each round the full checklist below —
correctness bugs, reuse/simplification/efficiency, and the repo-specific
items that follow. Nothing here is optional or a "beyond code-review"
extra; it's the whole review.

Every finding the review Agent returns must be tagged with one of these
severity buckets, prefixed onto the finding as shown in "The round loop"
step 1 (e.g. `1. [CRITICAL] file:line — problem — fix`):

- `[CRITICAL]` — security vulnerabilities, wrong/broken behavior,
  performance problems.
- `[NICE-TO-HAVE]` — DRY violations, missing test coverage, code-reuse
  opportunities.
- `[NITPICK]` — documentation, comments, naming, formatting-adjacent
  issues.

A failing `bundle exec rake` from the Verify step counts as `[CRITICAL]`
when tallying findings for the round log and CSV row.

The top-line priorities this repo cares about most: Ruby best practices
(DRY, semantic naming), gem publishing discipline (don't break public
interfaces unless necessary; document and version appropriately when you
do), and security. The bullets below are the concrete, repo-specific
elaboration of those priorities.

- **General AGENTS.md conformance**: read `AGENTS.md` (which `CLAUDE.md`
  imports) and flag any violation of it, not just the rules called out
  explicitly below — those are the ones worth spelling out because
  they're easy to miss, not the full list.
- **The elastic contract**: both paths of a squished method must return
  the same type. Flag any change where the LLM path, the deterministic
  path, or a `squish_fallback` return can produce a value that skips
  schema validation or result typing (`Definition#coerce`,
  `Definition#build_result`, `Schema#build`), or where `squished?`
  could report the wrong path.
- **Correctness & error handling**: the routing core
  (`lib/squishling/router.rb`, `wrapper.rb`, `definition.rb`) and the
  elastic path (`lib/squishling/invoker.rb`). Check the error taxonomy in
  `AGENTS.md`: provider/transport failures become `LLMError` (original
  kept as `cause`), setup mistakes become `ConfigurationError` and are
  never retried or sent to a fallback, invalid output becomes
  `InvalidOutputError` after `max_retries`. Flag both missing handling
  (a provider exception escaping raw) AND overly broad rescues — in
  particular anything that would catch or wrap exceptions raised by the
  user's own Ruby implementation, or that rescues `NotImplementedError`
  more widely than the routing fallback intends.
- **Strict schemas**: changes to `lib/squishling/schema.rb` must keep
  every payload sent to RubyLLM strict and keep rejecting `strict: false`.
  Changes to `lib/squishling/result.rb` must keep `nil` vs `[]` distinct
  for `optional` fields and keep typing consistent between paths.
- **Reuse / Ruby idiom / DRY**: semantic, expressive naming; idiomatic use
  of Ruby/Enumerable over manual loops where it reads better; no needless
  boilerplate. Settings resolution should go through the existing
  `squishling_lookup` (class → superclass) and `Definition`
  method-over-class-over-config fallbacks rather than new ad-hoc lookups;
  JSON normalization through `Schema.jsonify`.
- **Security**: everything sent to the LLM is built in
  `Invoker#payload` — only method arguments and explicitly named
  `squish_context` values may leave the process; flag anything that
  serializes instance variables wholesale, credentials, or clients.
  Watch error messages and logger lines (`InvalidOutputError#raw`,
  `config.logger`) for leaking API keys or more user data than needed;
  regexes applied to model output (e.g. code-fence stripping) for
  catastrophic backtracking; parsing for anything beyond plain
  `JSON.parse` (no `Marshal`/`YAML.load`/`create_additions`); generation
  `params` (`lib/squishling/params.rb`) for any path that lets a key
  override the model, messages, or strict output format; and shared
  mutable state (class-level ivars, `Schema::CACHE`, routing frames) for
  thread/fiber races.
- **Backwards compatibility / gem publishing discipline**: don't break
  public interfaces unless necessary — the public surface is listed in
  `AGENTS.md` (the `include Squishling` DSL, `Squishling.configure` and
  `Configuration` options, result objects, error classes). Renamed or
  removed DSL methods/options, changed error classes, or changed routing
  semantics need a clear migration path. Every user-visible change needs
  a `CHANGELOG.md` entry, but per `AGENTS.md` those entries and version
  bumps are written by `/prep-release` at the release boundary, not
  per-PR — so don't flag a diff for lacking one; do flag a breaking change
  whose PR description doesn't explain the migration path, since
  `/prep-release` needs that to pick the right version. Also check the
  runtime-dependency rule: no provider SDK and no new hard dependency in
  `squishling.gemspec` without a clear reason, and dev-only gems stay in
  the `Gemfile`'s development group.
- **RubyLLM compatibility**: where the diff touches how chats are built
  or answers are read (`Invoker#chat_options`, `Params.apply`,
  `with_schema`, `ask`, `response.content`), check it against the installed `ruby_llm`
  source (`bundle show ruby_llm`), not memory — e.g. in RubyLLM 2.x
  `response.content` stays a JSON String (Squishling parses it),
  provider-specific options go through `with_provider_options`,
  `models.find` takes `provider:` as a keyword, and `assume_model_exists`
  needs a provider.
- **Documentation**: per `AGENTS.md`'s "README and docs philosophy" — the
  README stays a landing page; anything needing more than one code block
  lives in `docs/<topic>.md` (`configuration.md`, `routing.md`,
  `schemas.md`, `failures.md`). Flag README/docs left stale or
  inconsistent with the code change, and abbreviated provider names in
  headings.
- **Testing**: new or changed behavior lacking corresponding RSpec
  coverage under `spec/`, and existing specs weakened (loosened matchers,
  removed assertions) to make them pass rather than fixing the
  underlying code. Specs stub `RubyLLM.chat` with `FakeChat`
  (`spec/spec_helper.rb`) — flag tests that only assert the stub returns
  what it was stubbed to return. Behavior that only a real provider can
  show (strict-mode acceptance of a schema shape, nullable handling)
  belongs in an `examples/` live scenario too. Would `bundle exec
  rspec`/`bundle exec rubocop` catch this? If a lint or test gap is
  obvious, flag it — but don't treat a green run as proof the review is
  done; lint and tests don't check most of the bullets above (interface
  breakage, the elastic contract, security, docs).

## Wrap-up

Once the loop converges or stops early (per the rules above), report the
result in this shape:

1. **Overall result**: `CLEAN` (N rounds, Verify passing) or `STOPPED`
   (issues remain — either the round cap was reached, whether from
   unresolved findings or Verify still failing, or no-progress detection
   fired).
2. **Verification status**: pass/fail result of the last Verify step
   (`bundle exec rake`) that actually ran.
3. **Per-round breakdown**: findings found vs. fixed vs. rejected each
   round, broken down by severity (a small table is fine — round /
   critical / nice-to-have / nitpick / found / fixed / rejected).
4. **All files modified**: complete list of files touched across every
   round.
5. **Remaining issues** (only if stopped early): unresolved findings with
   context on why they need a human decision.
6. **CSV run log**: once the result above is otherwise final, append one
   row per round to `~/loop-review-outputs/squishling.csv` (a
   Bash/file-write action — it does not commit anything, so it doesn't
   touch the never-commits policy in Safety). Create the directory and
   file with this header if either is absent:

   ```
   timestamp,branch,iteration,model,thinking_level,clock_seconds,tokens_used_approx,critical_found,nice_to_have_found,nitpick_found,total_found,issues_addressed,issues_ignored
   ```

   (The column is named `iteration` for consistency with the equivalent
   CSV in other Coolhand repos, even though this skill's own terminology
   is "round" everywhere else — populate it with the round number.) For
   each round, populate:
   - `timestamp` — `date -u +%Y-%m-%dT%H:%M:%SZ` at the moment the row is
     written.
   - `branch` — `git branch --show-current`.
   - `iteration` — the round number.
   - `model` — `default`.
   - `thinking_level` — the effort level used that round (default
     `medium`).
   - `clock_seconds` — the difference between the `date +%s` captured
     before spawning that round's review Agent (step 1) and the
     `date +%s` captured after that round's fix+Verify completed
     (step 4).
   - `tokens_used_approx` — the reviewer Agent's self-reported
     `TOKENS_USED` value for that round.
   - `critical_found` / `nice_to_have_found` / `nitpick_found` /
     `total_found` — that round's severity tally (a failed Verify counts
     as one `[CRITICAL]`).
   - `issues_addressed` — that round's fixed count.
   - `issues_ignored` — that round's rejected count.

   Use a plain `cat >> ~/loop-review-outputs/squishling.csv <<EOF ...
   EOF` append per row — no CSV quoting needed. Note in the final report
   how many rows were appended and the file path.

## Rationalizations to resist

- *"The first round already looked clean, I don't need a confirming
  round."* A fix round can introduce its own regression. Always re-review
  after applying fixes before declaring convergence.
- *"Rubocop passed, so the review is done."* Lint passing is not the same
  as the review being clean — lint doesn't check the criteria above
  (interface breakage, changelog/version discipline, security). Run both.
- *"This finding keeps coming back, I'll just keep re-applying the same
  fix and it'll eventually take."* If the same non-empty finding set
  repeats across two rounds, mechanical fixing isn't going to resolve it.
  Stop and surface it — looping past that point just burns rounds for no
  gain.

## Safety

- Never force-push or amend existing commits as part of this loop.
- The skill only edits the working tree (plus the one `git add -N` index
  mutation noted in Scope, for untracked files); committing and pushing
  stays with the user.
