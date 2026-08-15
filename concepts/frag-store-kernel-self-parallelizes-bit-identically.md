---
type: belief
id: frag-store-kernel-self-parallelizes-bit-identically
provenance: session 2026-08-15 — store-backed kernels, the auto-parallel rung
ts: 2026-08-15
tags: [koru, kernel, store, parallelism]
---

# A store-backed `self` kernel parallelizes bit-identically; the decision is cost, not just row count (belief)

`self` over a store writes DISJOINT rows — one thread owns `[lo, hi)` and no
thread touches another's rows — so splitting the row range across threads
produces results BIT-IDENTICAL to the serial loop at any thread split. There
is no FP-reassociation hazard, no accumulation order, and therefore no oracle
break: the byte-identical-output wall that rules out naive parallel `pairwise`
reductions does not apply to `self`. This is why the auto-parallel lowering
(`len` >= a floor → up to cpu-count threads, spawn failure/empty tail falling
back inline, never skipping a row) is correct by construction.

What the wall DOES apply to is the aggregate half: a `pairwise` or reduction
that sums across rows reorders FP additions per thread, so it needs the
deterministic-reduction contract (fixed-order chunks or compensated
accumulators) before it can parallelize under the byte-identical oracle.

Second half of the belief, from measurement: the speedup is not a row-count
function. A tiny 2-op body at 131k rows ran SLOWER parallel (40ms) than
serial (22ms) — spawn overhead (~10 threads) exceeded the per-row work; at
9-op bodies they tied (the measurement was process/insert-dominated). The
healthy decision is per-call over BODY COST × ROWS vs spawn cost, and the
real win lives in amortizing spawn across repeated frames (a persistent pool
and an in-process step loop), not in per-call thread creation. A fixed row
threshold is a stub of the real predicate.

What would correct this belief: measurement of a pool-backed, frame-looped
store kernel showing the expected multi-core scaling, or a body-work
estimate entering the compile-time decision so the threshold adapts to the
op count.