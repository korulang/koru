---
type: belief
id: frag-branch-ahead-count-lies-about-content
provenance: surfaced by the 2026-07-25 mass-merge of 30 worktrees — four branches reported unique work that had already landed on main under different hashes
ts: 2026-07-25
---

# A branch's ahead-count is about commit IDENTITY, never about content (belief)

`git rev-list --left-right --count main...<branch>` — and every UI built on it —
answers "how many commit objects exist on that side," not "how much work does
that side have that main lacks." Those diverge the moment a patch reaches main by
any route other than merging that exact commit: a cherry-pick, a re-commit from a
second worktree, a contest where several agents implement the same fix and one
wins. All of those are *normal* here, so the divergence is normal too.

The dangerous shape is not a branch that looks merged and isn't. It is a branch
that **looks alive and is already dead** — reporting "1 ahead", carrying a patch
main already has, and often sitting on a base from before main refactored that
same code. Merging it does not add work; it **reverts** main.

Measured 2026-07-25, surveying 30 worktrees / 38 branches before a mass-merge —
four of them, and every one looked like live work:

- `fable/tt2-tree-cycle-guard` reported 1 ahead. Its patch was on main as
  `f8a26f73`, and main had since refactored the same emitter line
  (`value` → `value_{d}`). Merging would have undone that refactor.
- Two `worktree-agent-*` worktrees held large uncommitted diffs (+239 and +25
  lines) that were losing candidates from a fix contest whose winner main already
  shipped. Against main those files were 250–270 lines of *deletion*.
- A third worktree's untracked "new" challenge doc was byte-identical to one on
  main.

## The instrument

Ahead-counts cannot see this; patch-ids can. Index main's recent history by
patch-id and test every candidate commit against it:

    git log --format=%H -400 main | while read c; do
      git show "$c" | git patch-id --stable
    done | awk '{print $1}' | sort -u > /tmp/main_patchids.txt

A hit means the patch is already on main under a different hash — exclude the
branch. Content-level equality, not object identity, is the question being asked,
so this is the tool that matches the question.

Patch-id is necessary but not sufficient: it normalizes whitespace and context
but still keys off the diff, so a patch that landed on main *and was then evolved*
will NOT match while still being stale (the tt2 case matched only because the
guard commit itself was intact). The second check is a straight
`git diff --stat main <branch> -- <the files it touches>`: if the branch's own
files come out overwhelmingly as DELETIONS relative to main, main is ahead and
the branch is superseded, whatever the ahead-count says.

## Why this is a belief and not a script

The reflex it displaces is trusting a branch listing as a work inventory. Under
[[frag-greenfield-breaking-is-the-job]] and the contest/candidate pattern the
project actually uses, the same fix routinely exists in several places at once and
only one becomes main's. So the corpus is *expected* to accumulate branches whose
content is dead while their commit objects stay unique forever — and no cleanup
pass makes that stop, because the pattern that produces them is the working
method, not a mistake.

Open: nothing enforces this. The survey is a thing an agent must remember to run
before a multi-branch merge, which is exactly the shape of knowledge that decays.
Evolving it out into a checked-in script that a merge runs first would be
strictly better than this prose.
