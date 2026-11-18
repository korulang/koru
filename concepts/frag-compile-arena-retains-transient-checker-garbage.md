---
type: belief
id: frag-compile-arena-retains-transient-checker-garbage
provenance: corrected 2026-11-18 — pass-boundary marks misattributed by current_pass position; auto_discharge_inserter fixpoint rebuild is the +12.9 GiB hog, evaluate_comptime +9.9 GiB, FlowChecker exonerated
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
