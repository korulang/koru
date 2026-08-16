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