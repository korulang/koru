# Cordis Gauntlet — First Pull: closer self-certification

**Date:** 2026-08-16 · **Reference:** `cordis-ref` (cordiverse/cordis) ·
**Ours:** KOPIUM bridge + `std/runtime`.

Per the gauntlet doctrine, one calibration pull precedes any fleet: the closer
is an instrument, measured from the real thing, never from its description of
itself. A closer that cannot report its own can't-tell fraction is not
calibrated. This file is that report.

---

## Scenario under test: retired provider with a live dependent

The deepest property for us — Cordis Theorem 63 (ordering) made code. A
provider of a declared key is withdrawn while a dependent that resolved to it
is still active. Ordained outcome: the dependent deactivates first, the
provider survives until it finishes; the shared context returns to
pre-composition.

## Three verdicts

| leg | verdict | evidence |
|---|---|---|
| **Theorem** | resolvable | Theorem 63 stated + proved in paper §4.4.3; the guard in primary source (see ledger). |
| **Cordis (reference)** | resolvable (70/70) | `bunx vitest run packages/core/tests` → 11/12 suites, 70/70 tests. 12th suite (`decorator.spec`) fails on package *resolution* only (bun didn't link the `cordis` workspace alias), not behavior. Lifecycle-critical suites all green: dispose×13, fiber×8, isolate×3, invoke×2, plugin×12. |
| **KOPIUM (ours)** | **can't-tell at 100%** | `EX-001`. The dependent-provider graph is inexpressible in `std/bridge`: flat possession, no dependency edge between handles. The scenario cannot even be written. |

## Closer honesty fraction

**unresolved / unclassified / can't-tell = 100% on the withdrawal-ordering leg,
0% on the recovery-exactness + close-panics-on-strand legs** (those are already
mechanical properties on our own seam, no Cordis needed).

Verdict: **do NOT launch a fleet yet.** The closer is not broken — the bar is
out of reach on one named axis. This is the ledger-grew-faster-than-score exit:
the finding (a missing capacity, worth more than the parity) is the deliverable
of this pull.

## POSTSCRIPT — the First Real Round (2026-08-16, same day)

The missing capacity is built. Guarded withdrawal landed in
`koru_std/interpreter.kz`: dependency edges derived at acquire time from
input args naming held handles, `dischargeAllHandles` now a guarded loop.
Pinned by `440_010_guarded_withdrawal` — and **falsified**: with the guard
neutered, the interpreter releases the provider `file_1` first (the exact
violation) and the test fails; with the guard, dependents-first and it passes.
Bridge cluster: 10/10 green.

**can't-tell on withdrawal-ordering: 100% → 0%.** The First Pull scenario is
now expressible, runnable, and diffable — the gauntlet has its first real rung.

## ROUND TWO — the LIFO rung (2026-08-16)

Second probe from the First Pull discharged: release order among
*independent* handles is now LIFO (reverse acquisition), matching Cordis's
accumulator (`disposables.splice(0).reverse()`, Theorem 16). Pinned by
`440_011_lifo_release_order`, falsified (forward iteration → red), guard
still dominates. Bridge cluster 11/11.

## ROUND THREE — the re-resolution rung (2026-08-16)

The spatial half: a defined flow is a provider of a verb; redefining it
must re-resolve the next dispatch (Cordis's notify cascade, Theorem
63/64). The outcome was not a new capacity — it was a **memory bug
behind an already-true surface**: the "durable" defined-flows table
stored thread-arena pointers that the next interpreter call clobbers;
redefinition only worked by arena-reuse coincidence (probe: stored key
read as `'xt)sh'`). Fixed by making `DefinedFlows` own its memory.
Pinned by `440_012_redefine_resolves`, falsified twice in a clean
worktree, cluster 12/12.

## ROUND FOUR — the recovery-exactness rung (2026-08-16)

The soundness invariant, φ(γ)=γ₀: the accumulator applies each inverse
exactly once. A handle explicitly discharged mid-session must not be
released again at hang-up. Pinned by `440_013_recovery_exactness` (only
b.txt released after a.txt is explicitly closed). The falsification was
the run's most dramatic: remove the discharged-check and the loop
re-releases both handles forever — 12M `close-file()` lines before the
30s timeout. Recovery-inexactness is a non-terminating doubled inverse,
which is exactly what the paper's invariant says it must not be. Cluster
13/13, ledger EX-004 closed.

## Why the reference is trustable as an oracle

- It is a passing, version-controlled implementation (not prose or a benchmark
  claim); the guard is byte-visible in `reflect.ts:161` and does exactly what
  Theorem 63 says.
- The recovery discipline is mechanically checkable: LIFO reverse-order
  disposal (`disposables.splice(0).reverse()` in `fiber.ts`), async inertia
  chaining, dependents awaited via `Promise.allSettled(fibers.map(f => f.await()))`.

## Seeds recorded for the real gauntlet

- **FIFO-vs-LIFO:** `dischargeAllHandles` (interpreter.kz:1733) releases in pool
  order (FIFO); Cordis releases LIFO. Unobservable today (handles independent),
  load-bearing the moment ordering exists. Pinned as a probe, not a bug.

---

**Board state before first round:** oracle live, ledger opened with EX-001,
closer calibrated at can't-tell=100% on withdrawal-ordering. Rung-1 self-oracle
(path to a wall) exists on KOPIUM's own seam: LIFO-recovery exactness and
close-panics-on-strand are already bool/byte properties `invariants/` can hold.
## ROUNDS FIVE-SEVEN — the LIFO convergence (2026-08-16, worktree)

Three candidate theorems, one mechanism. Chain, diamond, and dual-provider
shapes all release correctly — and all three falsification attempts (single
pass, guard deleted, first-dep-only) had NO bite, because LIFO + in-pass
marking makes ordered release structurally correct for any acyclic set. The
diamond is R2 restated with two leaves; the guard is defense-in-depth that
cannot be turned red after R2's LIFO flip. The catch: 440_014 + 440_015 pin
the shapes (regression value), EX-005/006/007 record the discovery — the
gauntlet's ordering theorems on this pool are carried by R2's one line.
