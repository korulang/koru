# auto_discharge: batch-per-sweep refactor (design note, no patch)

Measured 2026-11-18 on `koruc canvas/tests/oshun gallery.k` via
KORU_MEM_PROBE pass-boundary arena marks: the `auto_discharge` window
contributes **+12.9 GiB** of the ~23.4 GiB compile-arena total — half the
compile's memory in one pass.

## The mechanism

`AutoDischargeInserter.run()` (`src/auto_discharge_inserter.zig:1482`) runs
two fixpoint loops (`.full` then `.scope_exit_only`), each calling
`transformOneFlow` until nothing transforms. `transformOneFlow` returns
after the **first** flow it changes, and `replacedFlowResult` rebuilds the
program through `ast_functional.replaceFlowRecursive` →
`mapItemsRecursive` + `programWithItems` + `cloneModuleDeclWithItems`:

- fresh `items` slice (O(#items))
- fresh `Program` + `module_annotations` string-slice clone
- per-module-decl `logical_name`/`canonical_path`/`annotations` dupes
- cloned flow spine for the changed flow

Iterations ≈ number of insertion sites across the whole module graph;
cost per iteration ≈ program size. Total = **O(sites × items)** —
quadratic. Only the final `result.program` is consumed; every intermediate
spine copy is dead garbage the never-freeing compile arena retains.
Synthesized products and dead copies share `ctx.allocator`, so a scratch
allocator cannot separate them — the fix must reduce the *number of
rebuilds*, not relocate them.

**Already partially treated.** `mapItemsRecursive` shares unchanged items
by value — the O(change) rebuild contract added after the 003_ecs SIGKILL
(`ast_functional.zig`, comment above `ReplaceFlowCtx`). The residual
12.9 GiB is what survives that fix: every rebuild still allocates a
full-length `items` slice per module level (`allocator.alloc(ast.Item,
items.len)` unconditionally), `cloneModuleDeclWithItems` re-dupes
`logical_name`/`canonical_path`/`annotations` per changed module per
transform, and each iteration mints a fresh `Program` + annotation slice.
N transforms × O(items + modules·strings) of *fresh slice/string* allocations
still accumulates — sharing item *values* did not stop sharing nothing.

**Batching is semantics-safe by construction** (verified 2026-11-18): every
transform decision in `checkAndTransformFlow` reads only the target flow's
own `body.continuations`, the static `event_map`, and declaration lookups
(`findEventDeclByLastSegment`, `renderTemplateInvocation` — decls/templates,
never sibling flow bodies). Transforms only ever replace flows, so
cross-flow reads see identical decl state under batching; enablement across
transforms is preserved by fixpoint rounds (a transform enabled by another's
output lands next round, exactly as it lands next iteration today).

**Implementation seam:** `replacedFlowResult` gains a deferred mode — push
`(target_flow_ptr, new_item)` onto a pending list instead of rebuilding;
`transformOneFlow` becomes `transformAllFlows` collecting every flow's
first transform per sweep (all `checkAndTransformFlow` early-returns keep
working unchanged — they return per-flow, the sweep iterates flows);
sweep end applies all pending replacements in ONE
`replaceFlowsRecursive` (new `ast_functional` fn: `mapItemsRecursive` with a
pointer-keyed target set — pointers stay valid because the program isn't
rebuilt until sweep end). Two modes (`.full`, `.scope_exit_only`) share the
sweep loop. Estimated diff: ~150 lines across `auto_discharge_inserter.zig`
+ `ast_functional.zig`; the 14 `replacedFlowResult` call sites are untouched.

## The refactor: batch per sweep

Change the unit of transformation from "first flow per call" to "all
flows per sweep":

- `transformOneFlow` → `transformAllFlows`: walk items once, collect every
  flow needing transform, apply all replacements to one new program.
- Fixpoint rounds collapse from **sites** to **rounds** — typically 1–3
  (synthesized arms can enable further synthesis, but convergence is
  shallow; the 100k cap exists for pathology, not expectation).

### Memory math

| | iterations | cost/iter | arena retained |
|---|---|---|---|
| today | S (sites, ~10²–10³ on big graphs) | O(items + modules·strings) | S × spine ≈ 12.9 GiB measured |
| batched | R (rounds, ~1–3) | O(items + modules·strings) | R × spine ≈ ~40–120 MiB |

Expected reduction on the gallery compile: **~12.9 GiB → well under
0.5 GiB** for this pass; total compile arena ~23.4 → ~10.5 GiB
(evaluate_comptime's +9.9 GiB becomes the remaining hog).

## Risks / open questions

- **Interaction order.** Today each transform sees the program *with all
  prior transforms applied*. Batched sweeps apply transforms against the
  same input program — two transforms touching the same flow/continuation
  list could conflict. Mitigation: dependency analysis per flow (most
  transforms touch disjoint flows), or apply batch then re-scan — a
  transform that finds its target already changed reports
  `transformed=false` and the next round catches stragglers. Needs a
  regression pass over the auto-discharge test cluster.
- **`label_seed_map` / `event_map` state** accumulates across iterations
  today; batching changes when they're populated — audit for staleness.
- **`.scope_exit_only` mode** is a second fixpoint — same batching applies.
- Pointer stability: `flow` pointers into `program.items` invalidate after
  each rebuild today (rescanned each iteration); batched collection must
  snapshot targets by identity (path/index), not pointer, within a sweep.

## Non-goals

No mutable-in-place rewrite (larger blast radius), no allocator tricks —
the win is algorithmic: fewer rebuilds, same semantics.
