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

**`EX-004-RESOLUTION` — recovery exactness landed 2026-08-16.**
Status: CLOSED (the soundness invariant φ(γ)=γ₀, pinned).
The accumulator applies each inverse exactly once: a handle explicitly
discharged mid-session must NOT be released again at hang-up. Double-release
is a doubled inverse — the exact thing the accumulator exists to prevent.
- Pinned by `440_013_recovery_exactness`: open a.txt, open b.txt, close
  a.txt explicitly, hang up → only b.txt is released; `close-file()` for
  a.txt appears exactly once.
- Falsified 2026-08-16 with the discharged-check removed: the loop
  re-released both handles forever — 12M `close-file()` lines before the
  30s timeout. Timeout-red is the verdict; recovery-inexactness is a
  non-terminating double-inverse, exactly the paper says it is.
- Cluster after R4: 13/13 green in a clean worktree.

**`EX-003-RESOLUTION` — re-resolution is a memory bug, not a feature gap.**
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

**`EX-008-RESOLUTION` — confluence is carried, not earned (2026-08-17).**
Theorem 73 (order-independence: remove/replace/revert lands where the final
composition would have landed) was tested on its one un-pinned axis — a
REGISTERED handle held across a mid-session REDEFINE of a session-defined
flow. The property holds without any fix: at hang-up the held file still
releases exactly once via its recorded `close-file` event.
Why it is carried, not coincidental: the two structures are disjoint by
construction — a handle's `discharge_event` is DUPLICATED into the pool's
allocator at acquire time (`interpreter.kz:479`), while `define` mutates the
session's durable defined-flows table whose memory EX-003 made self-owned.
Discharge resolves from the scope's registered spec table, never by
re-reading the flow body. So replacing a provider can no more corrupt a
held handle than it can rewrite the pool.
Recorded as a finding, per the EX-006 diamond discipline: a pin that cannot
be falsified (the pre-existing architecture is the fix) proves nothing, so
no `440_017` was manufactured. The probe ran green and was removed. This
CLOSES the confluence theorem: ordering axis carried by LIFO (R5
meta-finding), resolution axis carried by acquire-time duplication.

**`EX-009-RESOLUTION` — progress/termination is carried (2026-08-17).**
The paper's progress guarantee (every composition eventually reaches a
state; the release loop terminates) was audited on the discharge loop. It
terminates by two structural guarantees, both already in the code:
1. Acyclic-by-construction: `acquire` assigns monotonically increasing ids
   (`interpreter.kz:427-429`) and a handle's `depends_on` can only name
   handles already held (lower id) via `findByHandleId` — a dependency
   cycle is unconstructible from sequential acquisition.
2. Monotone marking: `dischargeById` guards `!h.discharged`
   (`interpreter.kz:503-510`) and the loop skips discharged handles before
   the guard, so each `progressed` outer pass strictly decreases the
   undischarged count (bounded by n) — the loop cannot spin.
The falsification is already on record: EX-004's note — removing the
discharged-check made the loop re-release both handles forever (12M
close-file lines, 30s timeout-red). That timeout-red IS the progress
theorem's counterexample, already caught as recovery-exactness's
non-terminating double-inverse. Recorded as a carried finding, no pin
manufactured (diamond rule). This CLOSES progress: the loop always lands.

**`XL-R2-RESOLUTION` — recovery exactness, cross-language (2026-08-17).**
The exactness theorem (Thm 61: each inverse applied exactly once) is now
checked by the LIVE ORACLE, not just in-repo. Scenario: a parent owns two
provider children; the A child is explicitly disposed mid-session; the
parent hangs up. Invariant: each binding withdraws EXACTLY ONCE — the
explicit dispose plus hang-up apply A's inverse a single time.
- Cordis side (`xlang-r2-cordis.spec.ts`): green — measured
  `service|withdraw|storeA` = 1, `storeB` = 1 across the whole trace.
- Koru side (`440_013_recovery_exactness`): green — `release:a` = 1,
  `release:b` = 1.
- Measured artifact: Cordis re-emits `service|set` during notify (the R1
  documented set-artifact) — the invariant is on the WITHDRAW side.
- The closer is now multi-scenario (R1-ordering + R2-exactness) and the
  battery still discriminates: probe A (flat) fails R1-ordering while
  R2-exactness stays PASS — two theorems, one closer, independent verdicts.
- This closes the gap between "KOPIUM satisfies recovery-exactness"
  (in-repo, already true) and "the reference implementation agrees" (now
  measured). The 12M-line double-release Koru caught in-repo (EX-004) is
  the same class the oracle now guards cross-language.

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
## R5-R7 phase (2026-08-16, worktree branch gauntlet/r567)

**`EX-005-RESOLUTION` — transitive chain releases leaf-first.**
Pinned by `440_014_transitive_chain` (file → q1 → q2; release q2, q1, file).
Falsified by the pre-R1 flat shape: forward acquisition order releases the
file under its live chain — red. A second falsification (single-pass reverse)
had NO bite: LIFO + in-pass marking unblocks each provider within the same
pass. The re-scan is retry logic, not depth propagation.

**`EX-006-RESOLUTION` — the diamond is not a distinct theorem.**
The two-dependents-on-one-provider shape releases correctly with the guard
DELETED entirely — pure LIFO carries it, both dependents being leaves. The
diamond is R2 restated with two leaves, not a new property. Recorded as a
finding; no separate pin manufactured.
Attempted failed-teardown pin abandoned: a discharge dispatch that errors is
not expressible through a void discharge signature (the only honest proc
return), and no runtime panic idiom exists for the tester. The guard's
load-bearing case was NOT reached in this phase's search — the arity route
(a discharge proc requiring one arg the synthesized invocation lacks) does
not fail, because the dispatcher accepts it; the failed-teardown case
remains OPEN, not proven false. A follow-up path exists: the interpreter's
dispatch path carries NoBranchMatch / UnsupportedNode errors a discharge
could reach — the void-signature route was the wrong one, not proof of
inexpressibility.

**`EX-006-RESOLVED` — the failed-teardown case was found, and it was worse
than unreachable: a silent false release. (2026-08-16)**
The follow-up probe revealed a defect: a discharge event declared with the
discharge phantom (`<!query>`) but NO implementation (no proc, no flow
impl) gets a synthesized no-op handler, so the pool calls it, prints
`[BRIDGE] Invoked`, marks the handle discharged, and close reports SUCCESS
— while the resource was never released. The guard never fires because the
release never fails; it succeeds emptily. Releasing nothing while claiming
released is the one failure the recovery-exactness invariant forbids most.
Fix: the register transform now refuses to emit a discharge claim for an
unimplemented event (proc or flow impl required); the obligation strands at
hang-up and close panics honestly. Pinned by `440_016_failed_teardown_blocks_provider`
(EXPECT_TRAP + assertions: No-spec refusal, no silent Invoked, stranded
count named). Cluster 16/16 green with the gate in place.

**`EX-007-RESOLUTION` — dual provider: both edges outlive the dependent.**
Pinned by `440_015_dual_provider` (merge over a.txt + b.txt mints one handle
depending on both; release merged, then both files).
Falsified attempts: first-dep-only guard — NO bite (LIFO reaches the
dual-dependent first and in-pass marking clears both edges). Again LIFO.

**META-FINDING (the phase's real result):** LIFO release + in-pass discharge
marking makes ordered release structurally correct for ANY acyclic dependency
set. The dependency guard is redundant given LIFO: it earned its keep when
release was FIFO (post-R1), and R2's LIFO flip made it defense-in-depth that
no reachable shape can turn red. Even 440_010 (R1) is LIFO-carried — its
falsification flipped to forward-order, never consulted the guard.
Implication for the gauntlet: three candidate theorems (chain, diamond,
dual-provider) reduce to ONE mechanism (LIFO) plus retry logic. The paper's
ordering theorems, mirrored on this pool, are satisfied by R2's one-line flip
void. Guard is a belt that never has to fire.
