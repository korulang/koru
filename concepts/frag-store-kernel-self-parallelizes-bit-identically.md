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
(`len` >= a floor → a persistent pool of up to cpu-count workers, no row ever
skipped) is correct by construction.

What the wall DOES apply to is the aggregate half: a `pairwise` or reduction
that sums across rows reorders FP additions per thread, so it needs the
deterministic-reduction contract (fixed-order chunks or compensated
accumulators) before it can parallelize under the byte-identical oracle.

Second half of the belief, from measurement: the speedup is not a row-count
function. With PER-CALL thread spawn, a tiny 2-op body at 131k rows ran
SLOWER parallel (40ms) than serial (22ms) — spawn overhead exceeded the
per-row work. The fix was amortization: a PERSISTENT worker pool (std
Thread.Pool, lazily created once per process, reused per call) collapsed the
per-call cost to queue-µs and flipped the total-window measurement on the
heavy 9-op / 200k-row body: pool-parallel 21ms vs serial 25ms, even inside
an insert-dominated single-call process. The healthy decision remains
per-call over BODY COST × ROWS vs pool-queue cost, and the full scaling
curve still waits on an in-process frame loop (a step-over-store rung) so
the kernel dominates the process.

Constraint discovered with the pool: the pool is process-lifetime and never
freed, so it must allocate from an UNTRACKED allocator
(`@import("std").heap.page_allocator`) — koru's leak checker accounts every
`koru_allocator()` byte, and a pool holding thread stacks in the tracked GPA
would trip the gate at exit. A process-lifetime object on the page allocator
is not a leak by construction.

What would correct this belief: a frame-looped store kernel measurement
showing the expected multi-core scaling (the step-over-store rung), or a
body-work estimate entering the compile-time decision so the threshold
adapts to the op count.