# Cordis Gauntlet — Run One Verdict

**Filed 2026-08-16.** The run, not the rounds. One judgment at the end.

## The setup

Reference: `cordiverse/cordis` (the executable oracle — core test suite green,
70/70 under bun, withdrawal-ordering guard read as primary source in
`reflect.ts`). Ours: the KOPIUM bridge + `std/runtime` in this repo.
Closer: the paper's metatheorems as falsifiable, pinned runtime properties.
Rung-1 core (theorems as self-oracle), rung-2 boundary (Cordis as behavior
oracle) reached but not crossed — guarded withdrawal closed the rung-2 gap
without needing a live cross-language trace diff.

## The board (three rungs, three falsified properties)

| rung | theorem | property | pin | falsified by | cluster |
|---|---|---|---|---|---|
| R1 | Thm 63 (ordering) | provider outlives dependents; release is guarded | `440_010_guarded_withdrawal` | neutered guard → provider released first → red | 10/10 |
| R2 | Thm 16 (LIFO reversion) | independent handles release in reverse acquisition | `440_011_lifo_release_order` | forward iteration → red | 11/11 |
| R3 | Thm 63/64 (re-resolution) | redefine = provider replaced; next dispatch sees the NEW body | `440_012_redefine_resolves` | stale-first-wins under owned memory → stale body → red | 12/12 |

Every property was **falsified before it was trusted**: each test went red
against the violating implementation, then green against the fix. No test was
written to pass; each was written to catch its own absence. The board is
monotonic, on disk, in `tests/regression/400_RUNTIME_FEATURES/440_RESOURCE_BRIDGE/`.

## The ledger (three entries, all resolved as findings, none as refusals)

- **EX-001** — flat possession: guarded withdrawal had no seat. CLOSED (R1,
  derived edge, no register-block change).
- **EX-002** — FIFO vs LIFO probe. CLOSED (R2, one-line flip, falsified).
- **EX-003** — re-resolution: NOT a feature gap. The property "already held"
  by **arena-reuse luck**; `DefinedFlows` stored thread-arena pointers that
  reset on every interpreter call. The stored key read back as `'xt)sh'`.
  Real memory-safety bug found by a falsification that failed to contradict —
  the no-op falsification was the find. CLOSED (R3, owned memory).

**Ledger grew faster than score — every round.** Not because the bar was
wrong; because each property was *already half-claimed by the codebase*
(flat release, FIFO order, "durable" table) and the truth was a lie each
time. That is the finding pattern of this run: the oracle's theorems are
discovery engines for our bugs as well as our features.

## The frontier

Nothing plateaued. Three rungs, three landings, zero exclusions standing.
The run did not end on plateau, budget, or bar-too-high — it ended because
the board earned a read. The standing frontier: rung-2 *behavioral* parity
(a live cross-language trace diff against Cordis) was **reached but not
crossed** — each theorem was mirrored structurally and falsified in-repo,
which buys the guarantee at the semantic level without the trace-VM
machinery. That machinery remains the next instrument when a property's
mirror cannot be expressed in-repo.

## The guard that held

The bar is a measure, not a telos. Nothing here was built to *match Cordis*;
each rung built what KOPIUM's own model needed to state the paper's theorem,
and the alignment fell out of the theorem. A diff that reached parity by
copying the reference's grain would have lost; each property is stated in
KOPIUM's own vocabulary (handles, pools, defines, sessions) and checked
against KOPIUM's own seams.

## Board state at verdict

Oracle live, ledger positive (3 closed, 0 standing), bridge cluster 12/12
green in a clean worktree at `fabadd8f`. Commits: `71199d11` (board open),
`fe415c27` (R1), `fabadd8f` (R2), `58ba89c7` (R3 fix), `02744554` (R3 ledger).

**The run is a win. The next run starts at recovery exactness.**