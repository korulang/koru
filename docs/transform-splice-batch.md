# transform runner: batched write-back (design note)

Measured 2026-11-18 on `koruc canvas/tests/gallery.k` via per-pass
arena-delta instrumentation inside `walkAndTransformStages` +
handler-exit/iteration-end pairing in `applyTransform`:

- 175 fixed-point passes; transform `handler_fn` calls contribute **+0 MB**
  across all 170 applications — handlers are not the cost.
- ALL cost is the splice/write-back: `spliceSiteResult` routes every
  application through `ast_functional.replaceFlowRecursive` /
  `replaceInvocationNodeAndContinuationsRecursive` — a whole-program
  `mapItemsRecursive` spine rebuild per single transform.
- By transform: `stored` 80 apps +5.0 GiB, `query` 15 +2.3 GiB,
  `print.ln` 21 +1.7 GiB (std.store watch/query/print bodies); one `stored`
  splice alone +3.5 GiB. Window total ~9.8 GiB of the ~15.2 GiB compile
  arena (post-auto_discharge-fix baseline).

## Candidates

**A. Per-site batching (steelman).** `walkOnce` currently returns after the
FIRST transform; collect ALL matches per walk, apply them in one
multi-target write-back (the `replaceFlowsRecursive` shape already landed
for auto_discharge). Iterations collapse from sites (~170) to fixpoint
rounds (~2–5). Memory: ~9.8 GiB → ~0.3–0.8 GiB for the window.

**B. O(site) splice.** Replace the spine rebuild with path-local write-back
or in-place mutation. Rejected as primary: the AST is persistent by
contract — `mapItemsRecursive` already shares unchanged items by value;
the residual per-app cost is the full-length `items` slice per module
level + module string dupes + Program/annotation clones + the changed
subtree clone. In-place mutation would break the shared-subtree contract
(unchanged items alias the same node allocations across program versions)
— a mutated "unchanged" node corrupts every sharer. Real fix, wrong risk
profile for this leg.

## Why A needs a guard auto_discharge didn't

Auto-discharge batching was safe by construction: transform decisions were
flow-local (target flow + static event_map + decl lookups only). Transform
handlers here are NOT provably flow-local — the fixed-point comment
documents chaining ("if transform A creates new invocations … the next
iteration will catch and transform them") and source-order semantics
("earlier transforms complete before later ones run"). Store transforms
graft bodies that can themselves contain matchable invocations.

**Guard:** batch only transforms whose `SiteRef`s are structurally
disjoint — no site's `holding` continuation lies inside another site's
replacement region, and no two targets share a holding. Conflicting or
nested matches defer to the next round. Chaining is preserved BY ROUNDS:
a transform whose input is another's output simply doesn't match until the
next sweep — exactly as it doesn't fire until the next pass today.

Residual semantic risk: two disjoint-site transforms whose *outputs*
interact semantically (A's graft references B's site by name) — order
today is source-order; batched is simultaneous. Store transforms graft
self-contained bodies; named cross-references between simultaneous grafts
are not a known pattern, but the regression suite is the oracle, not the
argument.

## Memory math

| | passes | cost/pass | arena retained |
|---|---|---|---|
| today | S ≈ 170 sites | O(program spine) ≈ 56 MB avg, spiky to 3.5 GiB | ~9.8 GiB |
| batched | R ≈ 2–5 rounds | O(program spine) per round | ~0.3–0.8 GiB |

## Risks / open questions

- Site-disjointness check cost: SiteRefs carry `holding` pointers into the
  pre-sweep program — nesting test is pointer-containment over continuation
  arrays; must be exact or conservative (false conflict = extra round,
  false disjoint = corruption).
- `whole_program` results (tap transforms) cannot batch — they escape
  site-local placement entirely; keep sequential for those.
- `retarget_producer` write-backs resolve producers by real-tree lookup —
  batching must preserve lookup-against-current-program semantics.
- transforms/*.zig handler internals (siteView construction, SiteResult
  assembly) are an unaudited allocation surface — flagged follow-up; this
  fix targets the runner's spine rebuilds only.

## Verdict — REFUTED by measurement (2026-11-18)

Implemented guarded per-site batching (disjoint-enclosing-flow guard,
whole_program/comptime-removal barriers, round-level stagnant guard,
`KORU_TRANSFORM_SEQUENTIAL=1` escape hatch, `SiteWrite` multi-target
write-back in ast_functional). Result: **7/8 sampled 690_STORE tests
fail `backend-exec` with KORU161 "watch precedes its store's create"**;
sequential path passes the same tests clean.

Root cause: the disjoint-site guard covers *structural* overlap only.
Store-transform handlers READ program state their siblings produce —
`stored`/`create` transforms emit decls and ordering a `watch` handler
checks (rung-one ordering). In sequential mode each handler sees all
prior transforms' outputs; in batch mode every handler sees the
pre-round program, so ordering checks evaluate stale state. The
read-dependency is undecidable per-handler — no cheap guard exists.

Reverted: transform_pass_runner.zig + ast_functional.zig SiteWrite
machinery. The ~9.8 GiB stands as the honest cost of sequential
semantics for store transforms. Remaining lever: transforms/*.zig
internals audit (siteView copies, SiteResult product sizes, per-splice
flow clones) — the flagged follow-up — or a scratch split inside the
splice path itself.
## World Model
Signal: design — transform-runner memory is splice spine-rebuilds
(handlers +0MB); fix is guarded per-site batching, chaining preserved by
rounds; transforms/*.zig internals flagged follow-up.

## Membrane
Evolution: acknowledged-none

Generated with Devin
