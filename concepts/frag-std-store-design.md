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

**Rung one is BUILT and green (2026-07-05, branch `store`):** the (f)
subflow is real — `create` coordinates, appending per store the typed
cell, an apply event/proc announcing the written field as a terminal
branch (`{old,new}` payload usage-synthesized per the (c) lean), and the
write event implemented by a generated flow whose arms are the
transplanted interceptor+watch branches. This is the first
transform-minted callable with a Koru-level body in the compiler; the
cross-store cascade is ordinary calls through generated subflows.
Transplant purity (ruling a) is enforced at rewrite time with a
koru-level diagnostic. 690_001-004 run green; 690_006 rejects as
designed.

Key substrate facts flipped during the walk: the multi-cell capture
routing believed to be a RED frontier (320_036's own header) already
passes; boolean connectives in when-guards existed in the parser but were
never once exercised by the corpus until 020_036 pinned them green.
Implementation added one more: cloneContinuation's documented shallow
expression/source-pointer footgun bites for real — a transform rewriting
cloned bodies must swap in fresh structs or it mutates the original tree.
And the ecs-store gap analysis (2026-07-05) added a fourth: rung one's
non-i64 column wall is **scoping, not architecture** — kernel:shape
declares f64 fields green in the corpus (390_001) through the same
transform substrate store.kz uses, so compound columns (f32/vec3/mat4x4,
pin 690_020) are extension work, not invention.

**Rung two started (2026-07-05, branch store-rung-two): plurality is
real.** Bare-type seed fields (`hp: i64`) declare a PLURAL store — SoA
column arrays + len, insert/inserth (handle branch), per-query
qrow/qbody/qsweep units keyed by SOURCE LINE (transform order can never
skew unit numbering), row-addressed apply/write subflow, take
(swap-remove). Two load-bearing mechanisms: standing query enters carry
the insert site's `__site_line` as a comptime arg, so a query only hears
inserts below it in source (690_005 fires on insert, 690_008 sweeps
pre-existing rows instead of double-firing); and generated |zig procs
call generated events directly (`main_module.<n>_event.handler(.{...})`)
— which met dead_strip's koru-visible-only reachability model and was
answered by the designed `retain` annotation, not a workaround. The
parser now accepts dotted paths as destructure field names (ruling 6's
projection grammar; PARSE001 loosened per the maximalist tenet).
690_005 GREEN.

**Rung two grew five more greens (2026-07-05 late):** take obligations
(`<store-item!>` on the `| item` identity payload — Field.phantom, the
660_027 pattern; KORU030 now says "obligation" by name), UPDATE WHERE
(indexed lvalue head `store[row].field`; site-replacement transforms
preserve impl_of because a query body's head IS an impl flow's head),
multi-watch fan-out in source order, declared capacity with `| full`
exhaustion-as-a-branch, and T2's cascade-cycle rejection. The cycle
graph is **FIELD-level, not store-level** — the store-level version
false-positived on 690_004's same-store hp→shield derivation (caught as
a regression, reworked same session). Walker fact overturned: nested
`stored` sites transform BEFORE their enclosing create's head fires, so
coordination-time scans must read both spellings of a write (raw
`std/store:stored` and rewritten `__store_write_*`). 690 board:
11/11 runnable green, 9 TODO.

**The perf instrument (2026-07-05):** ecs_bench_suite's seven workloads
are mapped as the store's honest-ABSENT benchmark battery
(`koru-benchmarks/suites/ecs-store` — board, provenance, M2 Pro criterion
baselines of six reference engines). Three one-to-one ballparks
(simple_iter's ~3.3µs legion sweep is O13's falsifier bar), two
dissolved-by-design entries validating NO-ARCHETYPES (the engines
disagree with each other by 36-40× on the archetype pathologies), two
gap-namers (schedule = the rung-4 no-threads bet; serialize = the
O-numberless whole-store verb). Kernel stays separate: pairwise
relationship-math over held values is kernel's charter, standing rules
over named reactive state are the store's — the suite needs zero
pairwise. Idea pins now have a **residue tier** below the
provisional-spelling tier: TODO + residue.md, no input.kz, for ideas
whose surface is honestly uninvented (690_019 batch+fusion, 690_020
compound columns).

The full residue (rulings, stamped theses, gauntlet verdicts, open
queue) lives in `tests/regression/600_STDLIB/690_STORE/DESIGN.md`, which
deletes as pins absorb it. ECT/BLOOM (entity-component-taps) is
superseded by this design; its rings pattern is salvaged as the async
escape from the cascade.
