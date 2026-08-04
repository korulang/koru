---
type: belief
id: frag-milestone-suites-are-instruments
provenance: migrated from koru/CLAUDE.md 2026-07-24; ruled 2026-07-02 by Lars mid-triage
ts: 2026-07-24
---

# A milestone suite is an instrument that surfaces toolchain gaps, then drops off the work list (belief)

An application cluster — the AoC-2015 days, a benchmark board, a demo, a drag
race — exists for exactly one purpose: to **surface gaps in the toolchain**. The
moment it has surfaced them it has done its job. The gaps become the work list,
stated in the compiler's own terms (the missing language feature, the missing
diagnostic, the missing guarantee), and the milestone itself leaves the plan
entirely. Milestone tests go green **as a side effect** of the language becoming
capable. That is the only green that counts.

Nobody ever works *on* the milestone. Nobody commissions "green day N." Nobody
ranks work by which milestone entries it unlocks.

## Why this needs recording — code cannot hold it

The `810_AOC_2015` reds look, to any reader of the working tree, exactly like an
unfinished to-do list. Nothing in the suite records that they are **deliberate,
Lars-ruled honest-red roadmap markers** — that the reds are the point, and that
they are supposed to stay red until the *language* can express them.
`FRONTIERS.md` names each day's gap; the ruling that made them honest is commit
`e0097c96` ("the cluster stops lying"), which deleted every `.kz` host-workaround
facet, never to be slimmed again. Strip the prose and the intent inverts: the next
reader sees red tests and starts making them green, which is precisely the lying
that ruling removed.

## The inversion this repudiates — and its second layer

Ruled 2026-07-02 after a triage session ran the inversion twice in a row:

1. **Milestone over toolchain.** A triage correctly established the AoC reds as
   honest markers and surfaced a genuine core-toolchain defect (a silent stub
   fallback printing confident wrong answers) — and then recommended commissioning
   per-day solution work, with the compiler defect trailing as an optional
   side-question.
2. **The same inversion one layer up, under correction.** Told plainly that the
   toolchain came first, the plan was *reordered* but the frame was kept: "fix the
   toolchain wall first *so the AoC push is debuggable*." The compiler work was
   now step 1 — but justified by the milestone. The milestone was still the
   destination; the compiler was still the road.

Layer 2 is the load-bearing half of this belief, because it survived a direct
correction. **Reordering a plan is not the fix.** If the correction is "toolchain,
not milestone," the fix is the milestone leaving the plan, not moving to step 2.

## The detector

Run it on every plan: if a plan contains **"fix X so that \<milestone\> can proceed
/ resume / be debuggable,"** the frame is already inverted — X is being justified
by the milestone. Delete the clause. X is justified by the toolchain being the
product, full stop. Equivalently: catching yourself ranking "which days can we
green" is the signal to re-rank as "which compiler gaps do these reds name."
