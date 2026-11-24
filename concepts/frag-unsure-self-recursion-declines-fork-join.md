---
type: belief
id: frag-unsure-self-recursion-declines-fork-join
provenance: Osprey tak-par regression investigation, 2026-11-24 — quiet
  hel1 board measured tak-par 74.1ms under live fork/join vs seq 47.5;
  emitted-code audit showed all 13 other koru-par ports unaffected
ts: 2026-11-24
---

# Unsure self-recursive shapes decline fork/join to synchronous calls

The worklist asymmetry gate sorts self-recursive `[parallel]` tors into
asymmetric (→ worklist) and everything-else (→ fork/join). "Everything
else" secretly contains two classes: symmetric recursion (fib — fork/join
wins) and *unsure* recursion — permuted args, literals, complex terms
(`WlCallShape.has_other`). tak's three-way permuted fan-out is unsure,
and fork/join's spawn-per-call bookkeeping loses ~56% to plain sequential
on its exponential tree.

The ruling: unsure self-recursive shapes take neither lowering — the
marked self-call emits as a synchronous call, seq cost is the floor.
Symmetric keeps fork/join (proven win), asymmetric keeps worklist
(proven win), unsure declines rather than gamble. This is the same
posture as the asymmetry gate itself: when the classifier cannot prove
the expensive machine pays, take the cheap one.

Open: whether tak's permuted shape could ever earn the worklist is
unmeasured on quiet hardware — the spike branch never landed a commit.
If a future classifier extension proves finer granularity wins there,
this decline is the thing to revisit.
