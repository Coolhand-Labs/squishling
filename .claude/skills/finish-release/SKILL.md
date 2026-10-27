---
name: finish-release
description: |
  Finishes a release from its open release-prep PR (from /prep-release):
  squash-merges that PR, creates and pushes the annotated vX.Y.Z tag on the
  merge commit, then publishes the GitHub release notes in the same format as
  the previous release. Pushing the tag triggers the Publish workflow (RubyGems
  Trusted Publishing), so this is the step that ships the gem. Use when the
  user types /finish-release, asks to "merge and tag the release", "publish
  the release notes", "ship v0.x.y", or has just reviewed the release-prep PR.
user_invocable: true
version: 1.1.0
---

# Finish Release

The counterpart to `/prep-release`. That skill stops at an open release PR and
never merges, tags, or publishes; this one starts after the user has reviewed
that PR. **Invoking `/finish-release` is the user's authorization to merge that
PR, tag, and publish** (`AGENTS.md` names this as the one sanctioned path).
Order: **preconditions, merge, tag, release notes, report**. The release is
created with `--verify-tag`, so the tag has to exist first.

**What pushing the tag does:** `.github/workflows/publish.yml` runs on any
`v*.*.*` tag push. The build job runs RSpec and RuboCop, builds the gem, and
checks the tag matches `Squishling::VERSION`. The publish job then ships to
RubyGems via Trusted Publishing behind the `rubygems-publish` environment
(15-minute wait timer, no required reviewer). The Pages site (`pages.yml`)
deploys from `site/**` changes on `main`, not tags, so it is not part of this.

## Phase 1: Preconditions (abort on any failure, change nothing)

1. Find the release PR: `gh pr list --state open --search "chore: release in:title"
   --json number,title,headRefName,isDraft,mergeable,mergeStateStatus,body`. Its
   head branch is `release/vX.Y.Z` (per `/prep-release`) and its title
   `chore: release vX.Y.Z`. Zero or several matches: stop and ask. **Resume:**
   if no PR is open but one is merged (`--state merged`) and `origin/main` has
   the version with no tag, the user merged it by hand; skip Phase 2 and use
   its merge commit. If the tag already exists but no release does, skip to
   Phase 4 after confirming the tag points at the merge commit.
2. `git fetch origin main <head branch> --tags`. Read `X.Y.Z` from the PR head,
   not the working tree: `git show origin/<branch>:lib/squishling/version.rb`.
   The tag is `vX.Y.Z`.
3. Check all of these, and stop and tell the user which one failed:
   - `X.Y.Z` is greater than the latest tag (`git describe --tags --abbrev=0
     origin/main`).
   - On the PR head, `CHANGELOG.md` has a `## [X.Y.Z] - <date>` heading and
     `Gemfile.lock` has `squishling (X.Y.Z)`. CI installs the lockfile frozen,
     so a stale one is a bad release.
   - The PR is open, not a draft, `mergeable` and `mergeStateStatus` is `CLEAN`.
     `main` is not branch-protected, so a green merge button proves little:
     run `gh pr checks <n>` and require every check (CI matrix, RuboCop,
     exhale) to be passing, not pending.
   - The PR body does not flag unfinished validation. `/prep-release` writes
     live-example results there, and a release PR can say they were "NOT run"
     because no API keys were available. If so, show the user and confirm
     before merging.
   - The tag does not exist locally (`git tag -l vX.Y.Z`) or on the remote
     (`git ls-remote --tags origin 'vX.Y.Z*'`), and `gh release view vX.Y.Z`
     fails.

## Phase 2: Merge the release PR

1. Save the PR's current description outside the repo:
   `gh pr view <n> --json body --jq .body > "$TMPDIR/squishling-release-pr-<n>.md"`.
2. `gh pr merge <n> --squash --delete-branch --subject "release vX.Y.Z (#<n>)"
   --body-file "$TMPDIR/squishling-release-pr-<n>.md"`. The commit title drops
   the PR's `chore:` prefix (`--subject` is used verbatim, so keep the `(#N)`
   suffix), with the PR body as the commit body verbatim. Add no AI attribution
   (`AGENTS.md`). Never `--admin`, never bypass a check. If the merge is
   refused, stop and report.
3. `git fetch origin main --tags`. Take the merge commit from
   `gh pr view <n> --json mergeCommit` and confirm
   `git show <sha>:lib/squishling/version.rb` still says `X.Y.Z`.

## Phase 3: Tag

1. `git tag -a vX.Y.Z <merge commit sha> -m "vX.Y.Z"`. Tag the merge commit, not
   `origin/main` HEAD, so the gem ships exactly what `/prep-release` validated
   even if other PRs landed since. Annotated, so it records who tagged and when. (v0.1.0 to v0.4.0 are lightweight; either triggers Publish.)
2. `git push origin refs/tags/vX.Y.Z`. Push only that ref, never `--tags`.
3. Verify with `git ls-remote --tags origin 'vX.Y.Z*'`. The `git push` output
   can be swallowed by the shell's output filter, so don't trust its silence;
   the `^{}` line must show the merge commit.

Never `rake release` or `gem push`; CI publishes.

## Phase 4: Release notes

1. Fetch the previous release as the format template:
   `gh release view v<previous> --json body --jq .body`. Match its structure
   and tone: `## 🚀 What's New` (a one-paragraph summary in bold-keyword style,
   then the `gem "squishling", "~> X.Y"` snippet and a `Requires Ruby ...` line),
   then `---`-separated emoji sections: `## ⚠️ Upgrading from <previous>` first
   when anything breaks or changes behavior, one per feature (e.g.
   `## 🧩 Custom Harnesses`), `## 🔒 Security` (or `Security and Fixes`),
   `## ⚠️ Worth Knowing`, `## 🔗 Resources` (Documentation, Changelog,
   RubyGems). Keep only sections with content; there is no "Known Follow-ups"
   section. Re-derive the `Requires` line from the gemspec and README at the
   tag; it has changed between releases.
2. Source the content from the `## [X.Y.Z]` CHANGELOG section and the merged
   PRs since the previous tag (`git log v<previous>..vX.Y.Z --oneline`), reading
   the PRs and the diff for anything the changelog compresses. Write for users:
   what it does, a short code example for new API, and a before/after snippet
   for anything behavior-affecting. Use full `https://github.com/Coolhand-Labs/squishling/...`
   URLs (blob links to `main` for docs), not relative links.
3. **Verify every claim and every issue link before publishing.** For
   Worth Knowing, take the issues from the previous release and run
   `gh issue view <n> --json state` on each: drop closed ones, and re-read any
   issue the release touches (partly fixed counts as still open, with a
   parenthetical saying what was fixed). Don't describe a behavior you haven't
   read in the code or the PR.
4. Write the notes outside the repo, e.g. `$TMPDIR/squishling-release-notes-vX.Y.Z.md`
   (this repo has no gitignored scratch directory; never commit the file).
5. `gh release create vX.Y.Z --verify-tag --title "vX.Y.Z" --notes-file
   <that file> --latest`. Not a draft and not a prerelease. Confirm with
   `gh release view vX.Y.Z --json name,tagName,isDraft,url`.

## Phase 5: Report

State, in the final message:
- The merged PR number and its merge commit, and the tag pointing at it.
- The release URL.
- The Publish workflow run (`gh run list --workflow publish.yml --limit 1`) and
  whether the build job passed and the publish job is waiting out the
  `rubygems-publish` timer. Do not approve, re-run, or publish by any other
  route. Check the run again later if the user asks whether the gem is live
  (`gem search squishling --remote`, or the RubyGems page).

## Rationalizations to resist

- *"The version file on my branch says X.Y.Z, close enough."* Read it from the
  PR head, then from the merge commit. A stale checkout publishes the wrong code.
- *"Checks are probably green."* Run `gh pr checks`. Nothing else gates the
  merge: `main` has no branch protection.
- *"I'll use the default squash message."* The title and body are the permanent
  record of the release; pass `--subject` and `--body-file`.
- *"`main` has moved on, I'll just tag HEAD."* The release PR was validated at
  its merge commit; HEAD may carry unreviewed changes.
- *"I'll publish the notes first and tag after."* Without a tag, GitHub makes
  one itself from the branch tip, unannotated and unreviewed.
- *"The old Worth Knowing list is fine."* Issues get closed. Check each one.
- *"`git push` printed nothing, so it worked."* Verify with `git ls-remote`.
