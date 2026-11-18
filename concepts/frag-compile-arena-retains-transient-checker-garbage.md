---
type: belief
id: frag-compile-arena-retains-transient-checker-garbage
provenance: corrected 2026-11-18 — pass-boundary marks misattributed by current_pass position; arc closed: auto_discharge batch + lazy ast_functional rebuilds took compile arena 23.4 -> ~6 GiB; transform batching refuted on store read-deps
ts: 2026-11-18
---

# The compile arena retains transient rebuild garbage (belief)

The backend's `compile_arena` never frees until process end, so every
allocation a pass makes — including scratch it `defer deinit`s and
intermediate structures later iterations supersede — accumulates for the
whole compile. `ArenaAllocator.free` is a no-op.

Measured on `koruc canvas/tests/gallery.k` via pass-boundary arena marks
(2026-11-18), with the correction that `current_pass=` sits at inconsistent
depth in each proc — a mark names the pass *starting*, so a delta belongs to
the pass whose body ran between the previous mark and this one:

- `auto_discharge` window: +12.9 GiB — `AutoDischargeInserter.run()`
  (`src/auto_discharge_inserter.zig:1482`)
- `evaluate_comptime`: +9.9 GiB
- all other passes combined: ~0.4 GiB
- `check_flow`/FlowChecker: **exonerated** — <1 MB; a scratch-allocator patch
  for it was built, measured, and reverted for exactly this reason.

The auto-discharge mechanism is functional-persistent rebuilding, not checker
scratch: `run()` loops `transformOneFlow` to a fixpoint, each call transforms
exactly ONE flow, and `replacedFlowResult` routes through
`ast_functional.replaceFlowRecursive` → `mapItemsRecursive` +
`programWithItems` + `cloneModuleDeclWithItems` — a fresh items spine, Program,
and per-module string dupes per single-flow transform. Iterations ≈ insertion
sites, cost per iteration ≈ program size: O(sites × items), quadratic in
graph size. Only the final `result.program` is used; every intermediate spine
copy is garbage the arena retains.

Products vs scratch verdict: the synthesized continuations/@panic arms MUST
persist on `ctx.allocator`, and they are interleaved with the dead spine
copies on the same allocator — a scratch allocator cannot separate them.
Scratch-allocator does not apply here. The fix directions are structural:
batch all transforms per sweep (collapse iterations from sites to fixpoint
rounds) or mutable in-place transform; both are real refactors, not drive-bys.
`evaluate_comptime` (+9.9 GiB) remains unaudited at this depth — same
product-vs-temporary question applies.

UPDATE 2026-11-18: batch-per-sweep LANDED (`replaceFlowsRecursive` +
deferred `replacedFlowResult` + `transformAllFlows`, ~110 lines). Measured on
gallery.k: compile arena 23.4 -> 15.2 GiB (-35%); the auto_discharge window
12.9 -> 5.1 GiB (-60%), not the <0.5 GiB the design note predicted. The
residual is per-sweep transform TEMPORARIES — checkAndTransformFlow's trial
allocations (resolved_flow/nested_flow candidates, string temp) accumulate on
the arena across sweeps, plus more fixpoint rounds than the 1-3 estimate.
Next lever if pursued: scratch-split inside the sweep (winner flows to
pending, losers/temps reclaimable) — same product-vs-temporary boundary, one
level down.

Until then, ~23 GiB is the design's honest cumulative cost; the 3/4-RAM
default (`fc7527657`) sizes for it.

UPDATE 2026-11-18 (arc close): the evaluate_comptime window got the same
depth and the story completed. Sub-marks split it: Phase 2.4
`run_pass("transform")` held ~9.66 GiB of the ~9.9 GiB; comptime_main and
the filter were ~0. Per-pass arena-delta marks inside
`walkAndTransformStages` showed 175 passes, handler_fn +0 MB across all
170 applications — the cost was entirely splice/write-back, concentrated
in `stored`/`query`/`print.ln` (std.store transforms; one `stored` splice
+3.5 GiB).

Two fixes were tried and one refuted:

- Guarded per-site batching (disjoint-enclosing-flow guard,
  whole_program/comptime barriers, `SiteWrite` multi-target write-back,
  `KORU_TRANSFORM_SEQUENTIAL=1` escape): IMPLEMENTED, then REFUTED by the
  suite — 7/8 sampled 690_STORE tests failed KORU161 watch-precedes-create.
  Store-transform handlers READ program state siblings produce (rung-one
  ordering); the disjoint-site guard covers structure, not semantic
  read-dependencies, which are undecidable per-handler. Sequential
  one-transform-per-pass is semantic, not incidental. Reverted; the
  design note `docs/transform-splice-batch.md` records the refutation.
- Lazy rebuild in ast_functional (LANDED, two commits `021794601` +
  `dcfa1829e`): `replaceInvocationNode{,AndContinuations}InContinuations`
  and `mapItemsRecursive` were check-AFTER-clone — every splice
  deep-cloned every continuation of every flow and allocated an items
  slice for every module's items array, found or not. Now null-
  propagating: miss path allocates nothing, rebuild materializes only
  on the target path (`ensureConts`/`ensureItems`), unchanged positions
  share struct values per the O(change) contract.

Measured on gallery.k: transform window 10,190 -> 688 MB cumulative
arena (~97% collapse); compile arena ~23.4 -> ~6 GiB across the whole
arc. 8/8 KORU161 canaries + transform tests green.

What remains and why it's residual-not-hog:

- auto_discharge ~5.1 GiB: per-sweep transform temporaries
  (checkAndTransformFlow trial allocations) + extra fixpoint rounds.
  Scratch-split inside the sweep is the named next lever, uncommissioned.
- `replaceInvocationInContinuations` (third walker, ReplaceInvCtx) still
  eager-clones within containing flows — has a contain-pre-check but
  siblings on the path still deep-clone; smaller exposure, same fix
  shape if measured worth it.
- Live grafted products are negligible (handler_fn +0 MB) — the arena
  hog was never program content, always dead rebuild spines.

Lesson worth keeping: the arena's cost is O(rebuilds x graph), and every
functional-persistent write-back in the pipeline pays it per call. The
generic fix shape is lazy/null-propagating rebuild (clone only the
path), NOT batching (semantics may forbid it) and NOT scratch allocators
(products interleave with garbage on one allocator).
