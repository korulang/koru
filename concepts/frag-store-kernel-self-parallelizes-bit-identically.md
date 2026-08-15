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
freed, so it must allocate from an UNTRACKED allocator — musl's leaky
`koru_allocator()` accounting trips the gate at exit if a process-lifetime
pool leaks into the tracked GPA. The first untracked choice,
`page_allocator`, measured far too slow: the pool allocates a TASK NODE per
spawn, and 200 frames x 10 tasks became 2000 mmap/munmap syscalls. The pool
uses `smp_allocator` — fast small-node allocation, still untracked.

The ARITY HUNT (2026-08-15) — the honest threshold inquiry, three axes:
rows (8k to 262k), body weight (9-op to 40-op with @sqrt), frames per
process (1 to 500). Result: the store-backed `self` threading NEVER leaves
the noise band at ANY reachable configuration — deltas oscillate 0-6% and
change sign with noise (earlier single-point "wins" like 35 vs 39ms were in
this same band). The convergence is a tie everywhere. The baseline is the
story: the serial path is already near the machine's ceilings (memory
bandwidth ~48GB/s measured, and the process's user-time runs 4x wall even
in the serial build — the insert/store baseline already soaks available
cores), so the thread pool adds nothing separable. The GPU-style arity
(dispatch overhead vs task work) exists in theory, but its honest crossover
for this layout sits beyond every reachable point measured. The pairwise
disjoint experiment repeated the same tie (threaded 74ms vs serial 48ms was
a 1.5x LOSS at 512 rows — the only case that separated at all).

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

The decisive experiment (2026-08-15) is in and answers the value question.
Store-backed pairwise got a DISJOINT lowering at the parallel floor (each
row computes its own side; the k.other writes stripped; per-row work
threaded over the pool): serial and threaded are BIT-IDENTICAL (measured
exactly equal outputs at 512 rows x 512 pairs x 50 frames), so the
determinism claim holds. But the timing verdict: threaded 74ms vs serial
48ms — threading LOSES ~1.5x at the reachable scale. The 512-row store fits
in L2, the per-frame sync exceeds the per-frame compute, and the regime
where cores could pay (10k+ rows, working-set beyond cache) is UNREACHABLE:
the store+kor transform pipeline stops scaling around 1k flows
(TransformInfiniteLoop at 1024 inserts; 31s compile at 512) and a
loop-populated store cannot sit in front of a kernel (KORU010, pinned
390_116). The verdict: the parallelization pursuit as measured has no
positive value at the achievable scale, and the path to where it could is
blocked by toolchain scale gaps, not by the determinism question. The
CAPABILITY pursuit (store-backed kernels, bit-identical threading where it
applies) remains real. The disjoint pairwise lowering was reverted to keep
the serial form from regressing.