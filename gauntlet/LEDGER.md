# Cordis Gauntlet — Exclusion Ledger

In-tree, version-controlled ledger for the Cordis-parity gauntlet. One line per
exclusion, each with a reason. An exclusion is a **judgment** ("this is out of
scope") and belongs to the walk — nothing here is enacted by a contestant.

The bar is Cordis's spatiotemporal-composability calculus, executable via
`/Users/larsde/src/cordis-ref` (core = 70 tests, 11 suites, green under bun).
Ours is the KOPIUM bridge + `std/runtime` in this repo.

---

## Add

**`EX-001` — FLAT possession: the dependent-provider graph has no seat in KOPIUM.**
Status: **CLOSED 2026-08-16** (see `EX-001-RESOLUTION` below).
The withdrawal-ordering property (Cordis Theorem 63: a provider finishes
withdrawing only after every dependent that resolved to it has deactivated) is
inexpressible in `std/bridge`: one session, one `create(id, scope)`, all
handles in one flat pool, `close` → `dischargeAllHandles` releases every
undischarged handle with no dependency edge between handles. There is no
"handle A depends on key B and must be released before B". So on
withdrawal-ordering, KOPIUM is can't-tell at 100% — not wrong, **unnamed**.
Rationale: this is the skill's "bar too high, worth more than parity" exit; it
names the capacity to build (guarded withdrawal), it is not a reason to stop.

---

## Considered

**`EX-003-RESOLUTION` — re-resolution is a memory bug, not a feature gap.
Landed 2026-08-16.**
Status: CLOSED (the third rung found the property already "worked" — by
arena-reuse luck).
The spatial rung: a DEFINED FLOW is a provider of a verb; when the agent
redefines it, the next dispatch must resolve against the NEW body —
Cordis's notify cascade (provider replaced → dependents re-resolve,
Theorem 63/64) in the REPL's own mechanism.
The finding: redefinition only appeared to work. `DefinedFlows` stored
name/params/body as pointers into the interpreter's per-call thread arena,
which resets on every interpreter call and clobbers the stored bytes — a
probe read the stored key as `'xt)sh'`. `define` never truly replaced; it
re-hit the same offsets by luck.
The fix: `DefinedFlows` owns its memory — dupes key/name/params/types/body
into its own session allocator, fetchRemoves + frees the previous entry on
redefine, and deinit frees everything it owns.
- Pinned by `440_012_redefine_resolves` (define → shout → redefine →
  shout must see the NEW body).
- Falsified twice in a clean worktree (at fabadd8f; the working tree
  carried a concurrent uncommitted `transform_pass_runner.zig` edit —
  another session's, not ours): (1) pre-fix, the stored key reads
  clobbered arena garbage; (2) with owned memory + stale-first-wins, the
  test fails on the stale `echo:hi` body. With the fix, 12/12 bridge
  cluster green.
- The rung's shape refined: the paper's theorems are discovery engines
  for our BUGS as well as our features — the oracle named a property that
  was already "true", and proving the test caught its opposite surfaced
  the dangling pointers underneath.

**`EX-002-RESOLUTION` — LIFO release order landed 2026-08-16.**
Status: CLOSED (probe discharged).
`dischargeAllHandles` walks the pool in REVERSE acquisition order among
independent handles — LIFO, matching Cordis's `disposables.splice(0).reverse()`
(the paper's Theorem 16: effects revert in reverse application order). The
dependency guard (EX-001-RESOLUTION) still dominates: providers outlive
dependents regardless of LIFO.
- Implemented in `koru_std/interpreter.kz` (reverse walk in the guarded loop).
- Pinned by `440_011_lifo_release_order`: two independent opens, the
  second-opened file releases first.
- Falsified 2026-08-16: forward iteration (pre-LIFO) releases a.txt before
  b.txt and the test FAILS; LIFO passes.
- Cluster sweep after both rounds: 11/11 bridge tests green.

**`EX-001-RESOLUTION` — guarded withdrawal landed 2026-08-16.**
Status: CLOSED (the gap is closed, the exclusion is discharged).
The dependency edge is **derived, never authored** — no register-block or
grammar change. When an event creates a handle while one of its evaluated
input args names a currently-held handle in the same pool/scope
(`findByHandleId`), the new handle records that provider's pool id in
`depends_on`. `dischargeAllHandles` is now a guarded loop: a handle is
released only when no undischarged handle depends on it; dependents release
first, providers last — mirroring Cordis's `await Promise.allSettled(...)` in
reverse.
- Implemented in `koru_std/interpreter.kz` (Handle.depends_on, HandlePool.acquire,
  HandlePool.hasUndischargedDependents, dischargeAllHandles guarded loop).
- Pinned by `440_010_guarded_withdrawal`: `query(conn: file_1)` mints a
  dependent; the test asserts `close-query` fires before `close-file`.
- Falsified 2026-08-16: with the guard neutered (stash, rebuild, run), the
  pre-guard interpreter releases `file_1` first — provider under a live
  dependent — and the test FAILS on output. With the guard it passes.
- Cluster sweep: 10/10 bridge tests green (440_001…440_010).

---

## Removed

(none)

## Sources

- Reference: `cordis-ref/packages/core/src/reflect.ts` provide() disposer:
  `delete store[key]` → `notify([name])` (synchronous dependent refresh) →
  `await Promise.allSettled(fibers.map(f => f.await()))` → `delete fiber.store![name]`.
  The guard is real code, cited 2026-08-16.
- Ours: `koru_std/bridge.kz` `create`/`run`/`define`/`vocabulary`/`close`;
  `koru_std/interpreter.kz:1733` `dischargeAllHandles`.
- First Pull date: 2026-08-16.