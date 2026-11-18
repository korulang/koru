---
type: belief
id: frag-compile-arena-retains-transient-checker-garbage
provenance: KORU_MEM_PROBE arena marks on the gallery compile (2026-11-18): evaluate_comptime +9.9 GiB, check_flow +13.2 GiB of ~23.4 GiB total; vmmap showed ~22.5 GB writable VM_ALLOCATE
ts: 2026-11-18
---

# The compile arena retains transient checker garbage (belief)

The backend's `compile_arena` never frees until process end, so every
allocation a pass makes — including scratch it `defer deinit`s — accumulates
for the whole compile. `ArenaAllocator.free` is a no-op; a checker's
"cleanup" is bookkeeping, not reclamation.

Measured on `koruc canvas/tests/gallery.k` (KORU_MEM_PROBE marks at each
`current_pass` checkpoint, 2026-11-18):

- `evaluate_comptime`: +9.9 GiB
- `check_flow`: +13.2 GiB
- all other 18 passes combined: ~0.4 GiB

98% of the ~23.4 GiB compile-arena total sits in two passes. The allocating
construct is not one structure — it is the aggregate of per-scope/per-node
scratch: `FlowChecker` (`src/flow_checker.zig`, 3533 lines) builds
`StringHashMap(BindSite)`, `ArrayList(ScopedBind)`, `ArrayList(BorrowScopeBind)`
and string dupes per scope per node across the whole module AST; every
`defer ...deinit(self.allocator)` frees to the arena and reclaims nothing.
`evaluate_comptime`'s callees (`comptime_scan.run`, `callComptimeHandler`,
`checker.checkSourceFile`) show the same shape.

This refutes the "records never shared" framing: the cost is not live data
failing to dedup — it is transient garbage that was never reclaimable by
construction. The live set is a small fraction of the 23 GiB.

The fix direction is a scratch allocator per pass: hand `FlowChecker` (and the
comptime-eval callees) an allocator whose `free` works — a child arena or GPA
deinit'd at pass end — while AST/error outputs stay on `ctx.allocator`. The
open question is escape-safety: whether any checker-allocated value is
retained into `ctx.ast` or error lists. Verifying that across the checker is
a real audit, not a drive-by — until it is done, treat ~23 GiB as the design's
honest cumulative cost and size budgets accordingly (the 3/4-RAM default in
`fc7527657` does exactly this).
