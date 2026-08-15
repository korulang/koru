---
type: belief
id: frag-store-kernel-self-parallelizes-bit-identically
provenance: session 2026-08-15 — store-backed kernels, the auto-parallel rung
ts: 2026-08-15
tags: [koru, kernel, store, parallelism]
---

# A store-backed `self` kernel parallelizes bit-identically; the ceiling is body compute per byte, not rows or cores (belief)

`self` over a store writes DISJOINT rows — one thread owns `[lo, hi)` and no
thread touches another's rows — so splitting the row range across threads
produces results BIT-IDENTICAL to the serial loop at any thread split. There
is no FP-reassociation hazard, no accumulation order, and therefore no oracle
break: the byte-identical-output wall that rules out naive parallel `pairwise`
reductions does not apply to `self`. This is why the auto-parallel lowering
(`len` >= a floor → a persistent pool of up to cpu-count workers, no row ever
skipped) is correct by construction.

What the wall DOES apply to is the aggregate half. Store-backed `pairwise`
(added 2026-08-15, `k.other` -> partner-column, symmetric writes) is SERIAL
by design this rung: it writes BOTH endpoints per pair, so the rows are not
disjoint and the `self` parallel machinery must stay off until the
deterministic-reduction contract (fixed-order chunks or compensated
accumulators) lands.

Constraint discovered with the pool: the pool is process-lifetime and never
freed, so it must allocate from an UNTRACKED allocator — koru's leak checker
accounts every `koru_allocator()` byte, and a pool holding thread stacks in
the tracked GPA trips the gate at exit. The first untracked choice,
`page_allocator`, measured far too slow: the pool allocates a TASK NODE per
spawn, and 200 frames x 10 tasks became 2000 mmap/munmap syscalls
(pool-parallel 50ms vs serial 40ms). `smp_allocator` is the fix — fast
small-node allocation, still untracked — and parallel then beat serial
(35ms vs 39ms).

And the frame loop (step over store) is shipped and measured, which found
the real ceiling: for simple per-column updates the serial loop is already
MEMORY-BANDWIDTH-saturated. 100k rows x 5 f64 columns x 200 frames moves
~960MB of cache-line traffic in ~20ms ~ 48GB/s, near the M2 Pro's practical
limit — more cores cannot beat the bus for a bandwidth-bound body. The
parallel payoff is COMPUTE-bound bodies, and the compile-time decision must
therefore weight body compute per byte of traffic, not row count.

The honest comparison datum: the 50M-iteration five-body n-body as a
store-backed kernel measured 2.497s vs the literal fused kernel's 1.276s —
about 2x slower at N=5. That gap is the COMPILE-TIME KNOWN LENGTH the
literal form has (it unrolls the whole 10-pair loop) and the store form
structurally cannot have (the length is a runtime store property). The
literal form exists only for small hand-written N; the store form is the one
that scales, and its comparison at N=5 understates it by construction.

What would correct this belief: a compute-bound body (transcendentals,
pairwise sums with a deterministic reduction) showing multi-core scaling
that a bandwidth-bound column sweep cannot, at a store scale where the
kernel dominates the process.