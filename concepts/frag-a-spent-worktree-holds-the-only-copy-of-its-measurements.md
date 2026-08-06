---
type: belief
id: frag-a-spent-worktree-holds-the-only-copy-of-its-measurements
provenance: introduced 2026-08-06 — a worktree cleared for removal because "the work is landed" held four board snapshots that existed nowhere else, one of them the only record of a shipped wall's rejected first form
ts: 2026-08-06
---

# A spent worktree is spent for CODE, not for MEASUREMENTS (belief)

The test that clears a worktree for removal is "is its work landed?", and that
test is about commits. Board snapshots are not commits. In this repo they are
**tracked artifacts** — the whole history lives under version control, hundreds
of files deep, and that is what makes any past number recheckable at all. A run
performed inside a worktree writes its snapshot into *that* directory, untracked,
and it joins the record only if someone carries it over deliberately. Nobody
does, because by the time the worktree is being swept the code question has
already been answered yes.

So the removal reads as clean-up and is quietly a deletion. `git status` in the
worktree reports the residue honestly, and it reads like noise: a moved symlink,
a run artifact, some timestamped JSON. The branch is merged, the tests are green
on main, the directory looks like litter. Every signal says nothing is lost.

**The instance.** The worktree behind the debt-exists wall held four boards. Two
were routine. The other two are a *pair*, and the pair is the finding: the wall's
first form measured twenty tests worse than the branch baseline, and its narrowed
form measured back to parity. That before-and-after is the entire argument for
why the shipped rule is the narrow one — the evidence that the strict reading was
tried, priced, and rejected on data rather than taste. The commit messages assert
the conclusion; only those two snapshots can be re-read to check it. They were
absent from main and would have died with the directory.

**Why this is worth holding as a belief rather than a checklist line.** A
rejected alternative leaves almost no trace by nature. The code that survives is
the code that shipped; the discarded form exists as a sentence in a commit
message and a number in a file nobody tracked. That asymmetry is not specific to
worktrees — it is the general reason a measurement of a *road not taken* is the
first thing lost and the last thing reconstructible. A future reader asking "did
anyone try the strict version?" has to trust prose or redo the eleven-minute run
against a compiler that no longer contains the strict version at all.

**The move, when sweeping.** Carry the untracked snapshots onto main under their
own commit before removing the directory, and say what they measure. Not the
symlink and not the per-run artifacts — those are pointer state that the next run
owns. The timestamped boards specifically, because each one names a commit and is
therefore a claim someone can still check. This is the same corollary
[[frag-a-board-measured-on-a-dirty-tree-is-not-reproducible]] reaches from the
other side: preserve a measurement under its own authorship rather than folding
it into, or discarding it alongside, something else.

**Open.** Nothing makes a worktree run write into the primary repo's history, and
it probably should not — a filtered or experimental run has no business in the
published trail. But there is no signal today that distinguishes "this worktree's
boards are throwaway" from "this worktree holds the only copy of a decision's
evidence", and the person sweeping is the person least likely to know which they
are looking at.
