---
challenge: claim-audit
kind: frame
status: standing
yields: one external artifact's claims ruled blocker / not-a-blocker / unmeasured against the current tree, the survivors landed, the measured tree pinned
family: correctness
---

*Walker context — the recurrence that earned this frame. A read-only
architecture review (2026-08-30) asserted a dozen findings about this repo.
Checked against the tree the next day, its file lists had already moved: the
`src/*.bak` backups it listed were purged by `becc6a7f` before the review was
a day old, and its six "dead" modules were all live on the second clock — the
backend graph in `koru_std/compiler.kz` / `koru_std/build.zig`, which `zig
build`'s `exe.root_module` does not see (`frag-zig-build-does-not-compile-all-of-src`).
The review carried no tree pin, so its staleness was invisible by
construction. Measured 2026-08-31 (HEAD `22a9a618`): of twelve candidates,
two were already fixed by a purge commit, five misread the second clock, two
mislabeled deliberate infrastructure, and two-and-a-half findings survived
contact with the current tree.*

*The discipline that caught this now lives in AGENTS.md ("A claim from
another session is not ground truth") and in
`frag-a-header-citing-a-pin-is-a-measurement-at-write-time`. This frame is
that discipline made replayable — the family's whole-artifact organ. Its
siblings each police one organ of the claim surface: refusal-audit (010) the
suite's refusals, docs-without-prose (003) doc claims, board-triage (005)
standing reds, honest-board (016) the board's verdicts. This one takes the
artifacts themselves.*

---

## The brief (sealed — you are the contestant)

Pick ONE claim-bearing artifact that asserts things about this repo's tree —
a scan, an architecture review, a report, a blog draft, a prose note, a
header corpus, another session's summary. You may not pick an artifact a
previous replay has already ruled against the same tree — but the ground
moves, so an artifact ruled against an older tree is a new artifact the
moment the tree moves beneath it. That is the variance this frame is for:
the same review, re-audited against a newer tree, is not the same review.

For EVERY claim the artifact makes about the tree, establish which of four
things is true, with evidence from the current tree — then act differently
for each:

1. **True and actionable.** The claim names something the tree does not do.
   → Land it: fix the compiler, delete the dead code, wire the unwired,
   correct the stale comment. The tree changes; the claim goes green on the
   next read.
2. **False.** The claim is contradicted by the current tree. → Write the
   refutation with the evidence that kills it. This is a finding, not a
   failure — the artifact is now a record of what was true at its write time.
3. **True at write time, stale now.** The ground moved. → Re-measure against
   the current tree and land the current truth. Say what moved and when.
4. **Unverifiable.** You cannot establish it this session. → Say
   **unmeasured** and stop talking. Never guess to fill a verdict.

You may not close a claim by editing the artifact to match the tree. The
tree is the only authority; the artifact is a comment, longer.

## Ground yourself FIRST — the walls are already standing

Before acting on any claim, find the mechanism that already governs it, or
you will spend a day rediscovering a wall. The corpus of prior replays is
the tree itself: the suite (`tests/regression/`), the harness walls
(`scripts/regression_lib.sh`), the prose-check walls, the concept store, and
the memos of past audits that landed as commits.

The review's worst errors all came from measuring the wrong clock. Before
you rule anything "dead", "unwired", or "placeholder", check BOTH graphs:
`build.zig`'s `exe.root_module` AND the backend graph in `koru_std/compiler.kz`
/ `koru_std/build.zig`. A file that appears in neither is dead; a file in
either is live. Count with the enforcer's own predicate, not your reading of
the rule.

Pin your tree before you start: `git rev-parse HEAD` + branch + worktree.
Your verdicts cite the tree, never the artifact.

## What "done" looks like

- Every claim in the artifact lands in exactly one of the four buckets, with
  the evidence that put it there.
- The measured tree (commit + branch) is pinned at the top of your verdict.
- Bucket 1 and 3 survivors are landed as commits, with a control green at
  HEAD before the change.
- Bucket 2 refutations and bucket 4 "unmeasured" verdicts are written down,
  not committed to the tree as if they were claims about it.
- A count of how many claims shared a mechanism. If six "dead" modules are
  one two-clock misunderstanding, that is the finding, and it outranks the
  individual verdicts.

## Failure modes

- **Acting on an unverified claim.** The one move this frame exists to
  prevent. "Unmeasured" is a verdict, not a step one.
- **Measuring the wrong clock.** Ruling "dead" from `exe.root_module` alone
  is how the review named six live modules. Check the backend graph.
- **Trusting the artifact's file list.** The `.bak` list was true at write
  time and false within 24 hours. Re-check every file you touch, this
  session.
- **Fixing the artifact instead of the tree.** Editing a report to match the
  tree proves nothing about the tree.
- **Inventing a verdict.** Bucket 4 exists so you don't guess. "Stop
  talking" is a complete deliverable.
