# std/store — compiled-reactivity application state (design belief)

Application state in Koru is a **store**: a comptime-named, second-class,
plurality-native table whose only write path is `stored{}` and whose
subscriptions are **compiled into the write path** (tap-transplant
machinery, producer owns the guard) — never registered at runtime. The
design walk of 2026-07-04 established, across two adversarial gauntlets
and three hostile showcase programs, that this spine holds:

- One centralizing write-subflow per store (ruled f) hosts everything:
  spliced watches/interceptors, the atomicity lock, DI'd backend arms.
- One lvalue path grammar, four addressing heads (handle / declared key /
  query-row / elided singleton); positional index is never identity.
- CRUD lifecycle events (`inserted`/`updated`/`removed`) are the single
  primitive; maintained aggregates are the planner compiling queries into
  the same interceptor branches; `take` = `removed` + a store-named
  phantom obligation (a taken row cannot leak).
- Layout is the closure of the queries (projections → SoA columns,
  predicates → maintained views) — and NO ARCHETYPES: capability is data,
  the fused stripe replaces per-system iteration (one corpus read serves
  the whole workload; ruled O13).
- Writes interleave, never overlap: write + full cascade is the atomicity
  unit; the chain is the envelope lean covers multi-write grouping.

Key substrate facts flipped during the walk: the multi-cell capture
routing believed to be a RED frontier (320_036's own header) already
passes; boolean connectives in when-guards existed in the parser but were
never once exercised by the corpus until 020_036 pinned them green.

The full residue (rulings, stamped theses, gauntlet verdicts, open
queue) lives in `tests/regression/600_STDLIB/690_STORE/DESIGN.md`, which
deletes as pins absorb it. ECT/BLOOM (entity-component-taps) is
superseded by this design; its rings pattern is salvaged as the async
escape from the cascade.
