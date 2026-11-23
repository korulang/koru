---
type: belief
id: frag-worklist-lowering-for-proven-pure-recursion
provenance: Osprey coins-par vs bend-par, challenge 034 — fork/join's
  ~128 coarse tasks could not balance a skewed recursion tree; measured
  55ms vs 33.2ms bar until self-recursive pure tors lowered to a worklist
ts: 2026-11-23
---

# Provably-pure self-recursive tors lower to a stealable worklist (belief)

When a `[parallel]`-marked tor is self-recursive AND the compiler can prove
its body pure (self-calls, arithmetic, returns — no effects, stores,
handles, I/O), the emitter lowers it to an explicit worklist: each call
pushes an item onto a per-event deque, workers steal items, and the join
is a done-count wait. This is Bend's evaluation idea compiled as a Koru
strategy — but gated on a proof Bend never requires.

Three measured rulings came out of the build:

- **Depth-gated push breadth, not value floors.** Work-item count must be
  bounded by recursion DEPTH (`WL_PUSH_DEPTH`), not input magnitude — a
  value floor starves small-but-deep trees (fib n≤35 produced zero pushes
  under a value gate). Depth-12 gave ~4K items; depth-18 produced a 262K
  syscall storm.
- **One shared deque.** A thread-local-plus-spill hybrid starved because
  `help()` drained the local queue before it could spill — steal count
  went to zero. Single shared deque with an atomic length mirror won.
- **Asymmetry, not purity alone, selects the worklist.** The first cut
  lowered every proven-pure self-recursive tor — including symmetric
  recursion where fork/join already wins (fib-par ~34ms worklist vs
  ~20ms fork/join, same loaded box; worklist min 25.6 vs fork/join min
  18.2). Push/pop and done-flag polling is overhead on balanced trees;
  the steal-everything deque is the win on skewed ones. The gate now
  requires positive skew evidence: the marked self-calls must shrink
  different parameter sets (coins: `amount` on one arm, `kind` on the
  other) or the same param(s) by literal steps differing >2x.
  Symmetric literal-step recursion, non-literal steps on a shared
  param, permuted args, and single-call chains keep fork/join — unsure
  means the proven path, never the experiment.

The division of labor this establishes: fork/join + the SIZE_FLOOR guard
remains the path for everything the purity gate cannot prove AND for
proven-pure recursion that measures symmetric; the worklist is the
strategy for the proven-pure ASYMMETRIC self-recursive slice. The
compiler picks — that selection is the language-language claim made
executable: analyze the shape, prove the subset, compile the machine that
fits, keep the sequential path native.

Open: whether the worklist should also serve sequential mode (Bend uses
one binary for both via a `seq` flag — Koru currently keeps seq native),
and whether cross-tor mutual recursion qualifies once purity composes.
