# Auto-discharge residual: sweep temps are exonerated — the hog is synthesis-side eager clone

Status: design note, 2026-11-18. Follow-up to `auto-discharge-batch-per-sweep.md`
(batch-per-sweep landed `3b05134d0`, window +12.9 → +5.1 GiB). The residual was
attributed to "per-sweep transform temporaries." Direct measurement refutes that
attribution — same class of error as the FlowChecker mark-position misread.

## Measurement

Instrumented `transformAllFlows` (`src/auto_discharge_inserter.zig`) with a
per-call arena-total probe around every `checkAndTransformFlow` call, split by
whether the call added a `pending_replaces` entry (winner) or not (loser).
Gallery.k, `KORU_MEM_PROBE=1`:

- 14 sweeps × 92 flow calls = 1,288 calls total.
- Loser-path temporaries: **~0 MB across all sweeps.**
- Winner-path: one sweep at +1,004 MB, all others ~0 — i.e. essentially all
  measured call allocation is *winning transform products* (the rebuilt flows
  and synthesized arms), not temps.

Per-call temps are therefore **not** the residual. Scratch-allocator and
per-site temp classification are both off the table — there is no temp mass to
reclaim.

## Where the ~4 GiB actually sits

The probe bracketed only the per-call loop. The unmeasured remainder of the
window is:

1. **`replaceFlowsRecursive` per transformed sweep** — the write-back spine.
   Lazy `mapItemsRecursive` already null-propagates unchanged items, but each
   sweep with N pending targets still allocates O(targets × path-depth) fresh
   nodes, and module/item spine dupes along every changed path.
2. **Synthesis-side eager clones inside the winners** — the product side of
   the same disease:
   - `synthesizeNestedPanicArms` allocates a fresh `out` continuation array at
     *every recursion level* and copies every continuation struct
     (`out[i] = cont.*`) whether or not the subtree changed — O(forest) per
     transform, per sweep the flow is re-examined.
   - The rebuilt-flow construction dupes `annotations`, `pre_label`,
     `inline_body`, `preamble_code`, `module`, `impl_of`, `impl_variant`
     strings and `cloneInvocation` per transform — strings are small, but they
     run once per winner per sweep until fixpoint.
   - `cloneContinuationWithBinding` / `cloneContinuationWithReturnBinding` are
     shallow (struct copy + one string dupe) — exonerated.

Because winners' products must persist on `ctx.allocator`, none of this is
scratch-safe; it is the same lazy/null-propagating rebuild problem one level
down — inside the *synthesis* functions rather than the write-back walkers.

## Steelman

Extend the proven `ensureConts`/`ensureItems` null-propagating shape into
`synthesizeNestedPanicArms` (return `?[]ast.Continuation`, null = unchanged,
materialize only on changed paths) and audit the rebuilt-flow field dupes for
shareable subtrees. `replaceFlowsRecursive` is already lazy; its residual is
bounded by genuine product size.

Expected: synthesis clones drop from O(forest × winners × sweeps-that-touch-
the-flow) to O(changed paths). Honest estimate: the ~4 GiB unmeasured residual
shrinks by the unchanged-subtree share — likely the majority, since most
continuations in a flow are untouched by a given discharge.

## Risks

- `synthesizeNestedPanicArms` recursion interleaves "children changed" and
  "this node changed" decisions — the null-propagating return must distinguish
  three states (unchanged / children-only / self-changed) or rebuild eagerly
  when both fire. Contained: one function, ~60 lines.
- Fixpoint re-examination: a flow transformed in sweep k is re-scanned in
  sweep k+1; lazy synthesis makes the re-scan cheap but does not remove it.
- Semantic ordering unchanged — this is allocation shape only, same contract
  as `021794601`/`dcfa1829e`/`86ef763d4`.

## Rejected alternatives

- **Scratch arena per `checkAndTransformFlow` call** — refuted by the probe:
  loser temps are ~0; there is nothing to reclaim.
- **Per-site temp classification (~127 alloc sites)** — moot for the same
  reason.
- **Fewer fixpoint rounds** — rounds are semantic (obligation chains), not a
  tunable.

## Verification plan

`KORU_MEM_PROBE` before/after on gallery.k (expect the unmeasured ~4 GiB to
contract), KORU161 ordering canaries (690_002 et al.), filtered transform +
obligation suites, `--no-cache`.
