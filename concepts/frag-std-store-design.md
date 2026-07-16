---
type: belief
id: frag-std-store-design
provenance: introduced by 24d782f1 — test(pin): std/store design cluster — 690_STORE born (8 aspirational pins + DESIGN.md), 2 green substrate pins
ts: 2026-07-04
---

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

**And two more (2026-07-05, later still): stripe + the cross-store
reactive closure.** `stripe(store)` is real — announce-only re-dispatch
(peek proc reads CURRENT values, the announce subflow re-fires the same
watch arms; no write, so interceptors correctly do NOT run). And
690_013 closed the gauntlet's headline hole ("the filter tab that does
nothing"): a watch guarded on ANOTHER store's field splices an
announce-call into that store's write path, so writing `ui.mode` re-
evaluates game's guarded watch — level-trigger on write; edge-trigger
dedup stays undesigned. Emitter root-fix along the way: an empty
terminal arm in the expression path now emits `{}` instead of NOTHING
(`.mode => ,` was a Zig parse error). 690 board: 13/13 runnable green.

**The rung-two sweep total (2026-07-05 night): the runnable 690 board
went 8/20 → 15/21.** Chain envelope (write-all-then-announce-all — the
(i) lean executable; envwrite is the write-only half, announce the
dispatch half, so watches observe settled multi-field state), and f64
scalar columns (690_021, tier 1 of 690_020 — uniform-type singletons;
value-type threads through apply/write/envwrite/peek). Four pins stay
TODO with their walls named in-file: (k)-disposal gates 015/016, T8
design gates 017, whole-program rewrite gates 018's rvalue key paths,
rung-3 planner gates 019.

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

**REPUDIATED (2026-07-17): the store never provides a disposal verb.** A
brief detour built a store-provided `give-back` and declared the take
obligation "explicit-discharge-required." That was wrong, and the reason is
the load-bearing insight: **on a static scalar store there is no resource.**
`take` copies the row's values out and swap-removes the slot — no `malloc`,
no `free`, ever. So an obligation that guards nothing is theater, and a
store-provided disposer is the store *presuming* how to dispose a row it
cannot know the meaning of. The corrected model:

- **A bare store's `take` carries NO obligation — frictionless** (remove +
  return values). Rung 0 (2026-07-17) retired the `give-back` unit and
  transform; a bare `take | item i |> …` needs no discharge.
- **Disposal is a PER-STORE opt-in, and the discharger is USER-authored.**
  A store declaring `[entity(<name>)]` mints `<std/store:taken!>` on a named
  synthesized row type (`Enemy`), and the USER writes the discharger — the
  *despawn handler* consuming `<!std/store:taken>` (660_027's qualified-
  phantom pattern). The compiler names the obligation until one exists; the
  store never presumes the disposal. `destroy`/`delete`/re-insert are all
  just what the user's handler chooses to do.
- **Stability from the type/state split.** The obligation *state* (`taken`)
  is stable and shared across all stores; the per-store *type* (`Enemy`)
  carries identity, disambiguated by base-type filtering (as `close(*Conn
  <!active>)` only matches `*Conn`). So the obligation vocabulary never
  multiplies with store count — the generics property in the ergonomics.

The obligation earns its keep only where a row is an entity with despawn
semantics or owned-resource cells — a per-store author's call, not a
language-wide rule. This is the disposal edge of the wider vision: the store
as a per-store-specialized, statically-allocated, compile-time-reactive data
substrate (reactions fused into the one write path, like taps).

The full residue (rulings, stamped theses, gauntlet verdicts, open
queue) lives in `tests/regression/600_STDLIB/690_STORE/DESIGN.md`, which
deletes as pins absorb it. ECT/BLOOM (entity-component-taps) is
superseded by this design; its rings pattern is salvaged as the async
escape from the cascade.
