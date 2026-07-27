---
type: belief
id: frag-a-correctness-argument-in-a-comment-gets-reverted
provenance: surfaced 2026-07-27 when prose-check refused for hours against a dead pid; the leak behind it had been reintroduced by a later, locally-reasonable edit
ts: 2026-07-27
---

# A correctness argument that lives only in a comment gets silently reverted by the next edit (belief)

`run_regression.sh` acquires two locks and releases them from a shell `EXIT`
trap. Bash traps **replace** rather than chain: the last `trap ... EXIT` wins and
every earlier one is discarded. Whoever wrote the second trap knew this and said
so in a comment — *"This replaces the machine-lock-only trap set above, so it must
handle both"* — and correctly released both locks.

Then a third `trap ... EXIT` was added later, inside the `--parallel` branch, to
clean up two temp files. It was locally correct and locally obvious. It also
silently discarded the lock-releasing trap, so **every parallel run leaked both
locks** — and `--parallel` is how the suite is always invoked.

The reasoning that made the second trap right never reached the third. It lived
in a comment attached to the thing it protected, which is exactly where it cannot
be seen from the place that breaks it.

## Why the failure stayed invisible for so long

Both runners test the holder's liveness before honouring a lock, so they reap a
dead lock and carry on. The leak was therefore self-healing for the code paths
anyone watched, and produced no symptom at all in normal use.

It surfaced only through a READER — `prose_check.sh` — which trusted the lock
file without asking whether its holder still existed, and so refused to run its
first check against a process that had died hours earlier. The correct diagnosis
of that refusal is not "the reader is too strict": refusing beats inventing a
result, and the check was right to refuse what it could not know. The defect was
upstream, in a lock nobody released.

**A lock file is evidence, not proof.** Anything that reads one owes it a
liveness test, because the writer may have died in a way the writer could not
handle. Two of the three readers here already did; the third is why we noticed.

## What generalizes

- When a mechanism's correctness depends on *not* doing something elsewhere
  (don't add another EXIT trap; don't return early past this cleanup), a comment
  at the mechanism is the weakest possible place to say it. Prefer a shape that
  cannot be broken from a distance — one cleanup function every path funnels
  through — over a warning the breaking edit will never read.
- A self-healing consumer hides a producer's bug indefinitely. The tolerant
  readers here were not wrong, but their tolerance meant the leak had no
  symptom until something strict met it.

Related: [[frag-transform-boundary-discards-held-context]] (the same session's
other finding — a claim in a comment outliving the thing it described),
[[frag-a-watcher-off-the-normal-path-is-not-a-wall]].
