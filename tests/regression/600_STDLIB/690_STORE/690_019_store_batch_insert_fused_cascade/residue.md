# 690_019 — batch insert + fused cascade (residue pin)

Pinned 2026-07-05 from a design walk (Lars + Claude). **Residue-tier pin:** the
idea has no earned spelling yet, so there is no `input.kz` — the discipline is
that this file carries the full residual design until a spelling pin (and then
the feature) supersedes it. First pin of this tier; the harness counts a
TODO-only directory as 📝 TODO (`run_regression.sh:322-341`), excluded from
the percentage.

## The idea

Vectorized dataflow execution over the store's write path, licensed by two
things we already ruled:

1. **T2 makes the cascade graph comptime-visible and acyclic.** An acyclic
   comptime-known DAG can be topologically sorted and **fused**: the entire
   interceptor cascade for a write site collapses into one straight-line
   body — no calls, no dispatch. Rung one emits the cascade as real calls
   through generated subflows; fusion is a planner/emitter decision on top,
   not new semantics.
2. **"The queries are the layout" gives the planner SoA columns.** A batch
   insert — `insert` taking an array/list of rows — turns the fused body
   into a column-wise loop over dense memory: guards become masks,
   arithmetic interceptors (`shield = hp * 2`) become vector ops, aggregate
   maintenance (`total += new - old`) becomes a horizontal reduction. The
   emitter writes Zig; Zig has `@Vector` natively. Converges with the
   std/field "castles" dense-buffer charter rather than competing with it.

Staged writes complete the picture (Lars's append-only lean): branches
collect changed objects into a single delta list — the append log — and the
flush applies the batch through the fused cascade. Stage, sort, fuse, sweep.

## The two walls (named, not solved)

**Wall one — cross-row dependencies through shared state.** Row-local cascade
edges vectorize freely. The moment row *i*'s cascade writes a shared scalar
that row *i+1*'s guard or interceptor reads (running total, count), naive
vectorization reorders reads/writes and breaks ruling (h)'s atomicity story.
Fix is classification, not retreat — the planner tags each cascade edge:

- **parallel** — row-local → SIMD lane;
- **fold** — into a shared aggregate → reduction; sound when the op is
  associative (the delta-algebra soundness question the adversary round
  already flagged for MIN/MAX-under-removal applies here verbatim);
- **ordered** — genuinely sequential.

Per the no-silent-performance-degradation doctrine: an edge that can't be
classified parallel or fold on a declared-fast batch path is a **compile
error**, never a silent per-row fallback.

**Wall two — effectful watch bodies are the vectorization boundary.** The
data plane (interceptor arithmetic, aggregate maintenance, membership
re-evaluation) fuses and vectorizes; a watch body that prints or does IO does
not. The planes are already separate in the design.

## The bonus: batch = the transaction envelope

The adversary sweep flagged the missing batching/transaction primitive
("two independent field writes are two atomicity units; watchers see two
cascades"). A batch write path answers it from the performance side for
free: watchers observe one combined delta. Sibling of the (i) chain-envelope
(690_009) — the chain groups writes in one statement; the batch groups rows
in one apply.

## Rulings this pin waits on

- **O9 sibling (NEW):** does a batch fire per-row watches N times after the
  fused apply, or once with a plural payload (`! inserted rows` — spelling
  provisional)? Lean: plural arm, per-row as the degenerate case — the shape
  that keeps the fused fast path honest. Genuine semantics call, Lars's.
- **Batch-insert surface spelling:** uninvented. Do not write it in a test
  until walked.
- **Edge-classification rules** (parallel/fold/ordered) as part of the
  planner design, including the associativity requirement on folds.
- **Prerequisite:** rung two plurality (690_005/007/008) — no tables, no
  batches. Neighbors: 690_009 (chain envelope), 690_014 (stripe).

## Promotion path

residue pin (this) → spelling pin (provisional `input.kz`, honest red) →
green when the planner lands. Delete this file's speculative parts as they
become rulings in DESIGN.md; the pin dissolves into real tests.
