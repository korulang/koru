---
challenge: store-kernel-seam
kind: frame
status: standing
yields: a kernel computes over a store's rows without the store's identity being smuggled in, or the seam is proven to need a spelling
family: stdlib
---

*Walker context — the recurrence that earned this frame. This is the one move
Lars **ruled** on 2026-07-30: the store↔kernel seam comes **before** any
`cross`/multiplicity spelling. That ruling is settled — do not re-open it as a
pending question.*

*It is also the best-instrumented problem on the board. The measurements exist,
the fork has been decided by commissioned reading, and the blocker is located to
a single sentence. What it lacks is the work.*

---

## The brief (sealed — you are the contestant)

Make a kernel's computation reach a store's rows. The blocker is known and
narrow: **a row binding does not survive nesting.**

Do not merge the two subsystems. Do not design a multiplicity spelling.

## Ground yourself FIRST — this is the most-measured problem we have

Read `baton_kernel_view_multiplicity_and_store_soa_seam` before anything else.
Everything below is from it, already established, and re-deriving it is waste:

**Measured layouts.** `std/store` is **typed SoA** (`690_005`, `690_049`).
`std/kernel` is **AoS with its SoA hint stubbed** (`390_010`). And the store's
sweep is **row-major over its own columns** — the worst available combination.

**The fork is ruled.** By commissioned reading @`d38d1334`: **(A) view
multiplicity.** The competing read — "(B) is cheaper" — was **wrong**, and the
reasons are recorded: `collectKernelOps` has no ownership boundary, and
`KernelOp` carries no binding attribution.

**No store↔kernel merge.** Import the **fact** (set identity ≠ element binding),
not the data. This is a boundary, not a preference.

**`cross(A,A)` IS `pairwise`** — FMM fits as an *argument*, not a feature.

**`std/kernel:step` was legal only via the fallthrough**, and a nested
`kernel:init` was **swallowed** — the dataset was never emitted. That is loud
now; it was silent before, which is why the measurements above are trustworthy
only from that commit forward.

## What is already proven to work

Probed @`477e763d`:

- An **all-`f64` container works** — `690_111` is green.
- **Elementwise-over-a-store works today.**

So the seam is not hypothetical. It is one property short.

## The actual blocker, stated precisely

**A row binding does not survive nesting.**

- `690_110_nested_sweep_outer_row_is_readable` — silently reads the **wrong
  store**. Silently. It produces a running program with wrong output.
- `690_112_nested_sweep_same_store` — the same-store twin, so the fault cannot be
  blamed on cross-store resolution.

⛔ **`690_087` is NOT evidence.** It has one row per store and its body never
reads the outer binding. If your diagnosis leans on it, the diagnosis is wrong.

## Why it fails silently, and why that matters most

The store is **text, not a symbol** — see `baton_store_is_text_not_a_symbol`.
`new`'s whole-program Walk rewrites `<store>.<field>` **before any scope exists**,
so a store name wins on **pass order**, not on a resolution rule. Rule 4 of
`690_086` — bindings innermost first — is **designed and not implemented**.

That is the same fault behind `690_090` (a sweep arm's row binding losing to a
store name), and it is why the failure mode here is wrong output rather than a
compile error. **A silent wrong answer is worse than a red test**, so any fix
that makes this loud is worth landing even before it is made correct.

The recorded design answer is a **type registry** — and it must earn its way by
**deleting the four separate `fieldOrder`-shaped re-derivations in `store.kz`**,
not by being architecturally nicer. If your change adds a registry and deletes
nothing, it has not earned it.

## The pre-garden

- **Five rewriters in `store.kz` now share `ast.expressionMask`.** Confirm that is
  still true and that no sixth has appeared unmasked. The prose hazard — a bare
  store name is an ordinary English word — bit **three times** in one session
  (sweep's rewriter, the plural rewriter, and a migration script) and it fails
  **silently**. Tooling needs its own copy of the mask.
- **Authors are safe; the tax is on us.** Measured: a store named `pool`, with
  `pool` three times in one string, is clean. Do not re-open that as a user-facing
  problem.
- **Check the 690 red list against the board, never against memory.** Sixteen are
  red as of `f1a74bd1`, and three of them (`690_110`, `690_112`, plus the store
  arc's deliberate pins) are **intentional**. A control's baseline comes from the
  board.
- **Commit a control green at HEAD before the change that needs it.** `690_097` is
  the pattern that paid.

## What "done" looks like

- A row binding that survives nesting, with `690_110` and `690_112` green — or, if
  that needs a spelling, the question written with the reads that raised it.
- The silent-wrong-output path made **loud** even if not yet correct.
- If a type registry lands: four `fieldOrder` re-derivations deleted, counted in
  the report.
- The elementwise-over-a-store path exercised end to end past `690_111`'s
  all-`f64` case.
- Multiplicity **not** designed. That is the next frame, and it is downstream of
  this one by ruling.

## Failure modes

- **Re-opening the ruled fork.** (A) view multiplicity. Settled.
- **Proposing a `cross` spelling.** Ruled to come after. And `cross(A,A)` is
  already `pairwise`.
- **Merging the subsystems** to make the data reachable. Import the fact.
- **Leaning on `690_087`.**
- **Editing `koru_std/` or running `zig build` while a suite is live.** The lock
  guards suite starts, not the sources underneath one.
