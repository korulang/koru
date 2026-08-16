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
Status: OPEN (a gap, not a refusal).
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