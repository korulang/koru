---
type: belief
id: frag-an-ignore-rule-is-a-bet-on-the-repos-shape
provenance: landing Composer 2.5's koru-lsp tree 2026-07-30 — `git add -A tools/` reported success and staged both package-lock.json files while silently dropping both package.json manifests and the launch config, against a bare `package.json` rule written when this repo was pure Zig
ts: 2026-07-30
---

# An ignore rule is a bet on the repo's shape, and it does not resign when it loses (belief)

`.gitignore` line 211 of this repo said `package.json`. Unanchored, so it matches
at every depth. It was correct the day it was written: koru was a Zig tree, the
only way a `package.json` could appear was as npm debris blown in from a scratch
experiment, and a blanket rule was the cheapest way to keep the tree clean.

Then a tool tree arrived — a TypeScript language server and a VS Code client,
whose *entire definition* is two `package.json` manifests. The rule did not
notice. It executed its 2025 intent against a 2026 corpus and amputated the new
work at exactly the files that made it work, and `git add -A tools/` exited 0.

## Why this is the vacuous-clean shape, not a config typo

[[frag-a-check-that-cannot-match-reports-clean]] is about a guard that runs and
cannot match. This is the mirror: a guard that runs and matches *too much*, on a
corpus it was never aimed at. The signatures converge, because both end in an
operation that reports success while doing a fraction of the work. `git add` has
no vocabulary for "I added eleven of thirteen and the two I skipped are the
important ones." Success and partial success are the same exit code.

The tell was there and it was legible: **the lockfiles landed without their
manifests.** A `package-lock.json` with no `package.json` beside it is not a
state any tool produces — it is only ever the residue of a filter. Any partial
amputation leaves a matched pair split like this somewhere, and that asymmetry is
cheaper to notice than the absence itself, because an absence has to be
predicted before it can be seen and an orphan only has to be looked at.

The trap was also, already, *known here*. Four lines above, the `.claude/*` rule
carries a `!.claude/skills/` re-include and a comment explaining that the project
skills ship with the repo. Someone hit this exact class, solved it correctly, and
did not generalise — because there was nothing yet to generalise to. The fix is
never the hard part. Knowing the rule has gone stale is.

## What follows

- **A blanket ignore rule ages against the repo, not the calendar.** The moment a
  repo grows a second language or a tool tree, every unanchored rule written for
  the first one is a live hazard and should be re-read as a set.
- **Prefer anchoring to blanketing.** `/package.json` would have expressed the
  actual intent — keep npm debris out of the *root* — and would have cost nothing
  and caught nothing wrongly for a year.
- **After adding a subtree, count what landed.** Not "did the command succeed"
  but "are the files I would name as this thing's definition in the index." For a
  tree of 18 files that is one `git status --short | wc -l` against a number you
  say out loud first.

## Open

Whether this deserves a mechanical check — a pre-commit that flags a staged
lockfile whose manifest is neither staged nor tracked. It generalises past npm
(`Cargo.lock`/`Cargo.toml`, `uv.lock`/`pyproject.toml`) and it is the orphan-pair
tell written down. Unclear whether the class is frequent enough here to earn a
gate, or whether that is one more cheap check accruing unearned trust.
