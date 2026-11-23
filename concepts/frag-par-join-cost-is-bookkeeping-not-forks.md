---
type: belief
id: frag-par-join-cost-is-bookkeeping-not-forks
provenance: Osprey fib-par/coins-par decomposition, 2026-11-23 — challenge
  034 fork-economics replay; DEPTH_CAP 0-vs-7 and depth/live-cap sweeps on
  emitted Zig isolated the par-vs-seq gap to join bookkeeping
ts: 2026-11-23
---

# [parallel]'s sequential-path cost is join bookkeeping, not fork mechanics (belief)

When a `[parallel]`-marked recursion runs slower than its sequential twin,
the first suspect is per-call emission overhead — specifically joins
executed for calls that never forked — not spawn/join mechanics.

The decomposition that settled it (Osprey fib-par): forcing `DEPTH_CAP=0`
left every marked call on the inline path while keeping all scaffolding,
and measured identical to `DEPTH_CAP=7` — fork count contributes ~nothing.
Sweeping `DEPTH_CAP` 4→10 was flat for the same reason. What remained was
~30M `waitAndWork` calls on waitgroups whose spawn branch never ran:
`pool_ready` goes true once and stays true, so every inline completion
paid a non-inlined pool method at the join. A per-callsite spawned flag
recovered ~20–25% on both par kernels. The shared live-task atomic was a
second, smaller cost (~3ms), amortizable only in per-thread probe/permit
batches — a naive budget still re-checks every call while saturated,
which is the hot state.

The ruling this supports: optimize the inline path before touching fork
depth, task caps, or pool configuration — the caps were already near their
measured optimum (live-CAP 24/48 collapsed to 174/60ms on fib-par; 128
was best). What fork/join still cannot do is balance skewed trees: coins'
`amount-c` vs `kind-1` subtrees differ by orders of magnitude, and ~128
coarse tasks leave a straggler tail no depth or size guard removes —
that residual is granularity, and closing it is a different mechanism
(work-stealing at finer grain), not a tuning knob.

Open: whether the probe/permit overshoot bound (PROBE × threads over CAP)
needs a tighter ruling for non-recursive wide fan-out, where the depth
cap does not bound total spawns the way it bounds recursive trees.
