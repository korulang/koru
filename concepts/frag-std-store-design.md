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

**Rung 2 landed (2026-07-17, 690_023 green / 690_024 the MUST_FAIL wall):**
`[entity(<name>)]` on the create annotation synthesizes a user-nameable type
alias (`enemy` → `const Enemy = __KoruStoreRow_enemies`) and makes `take` mint
`<taken!>` on `Enemy`. The user's `event discharge-enemy { enemy: Enemy<!taken> }`
consumes it — 660_027's base-type-filtered discharge, reused whole. Crucial
spelling fact: **`taken` is an UNQUALIFIED (local) state**, not `std/store:taken`.
Both mint (take unit) and consume (discharger) live in the user's module, so a
local state is correct — and it sidesteps a real emitter limitation: `writeFieldType`
(emitter_helpers ~848) falls back to a *phantom's* module to qualify the base
*type* (right for `*Field<std/field:field>`, where type co-locates with state;
wrong when base-type and phantom-state are in different modules, as the store's
`Enemy`/`taken` are). PARKED: lifting that so a module-qualified store obligation
resolves its base type independently — the base-type≠phantom-state orthogonality
made an emitter rule.

**Rung 4 opened — plural lifecycle interceptors are BUILT (2026-07-17,
690_016 green):** `! inserted { f } |> …` and `! removed { f } |> …` on a
plural `new()` now fire from the write path itself, closing the gap the
design named at line 21 (CRUD lifecycle is the single primitive) for the
insert/take half. The mechanism is the **qbody transplant reused whole**:
each interceptor becomes an event whose inputs are its destructured row
fields plus an impl flow carrying the body, invoked from the generated
insert/take |zig via `main_module.<n>_event.handler(.{…})` — inserted after
the row append and before standing query enters (the contract runs before
subscriptions observe settled state, (h)), removed before the swap-remove
with the row's outgoing values. So a store keeps a sibling aggregate
coherent with no bus and no dispatch, on row birth/death as well as field
writes — the reactive-substrate belief now covers CRUD, not just mutation.
`updated` and field interceptors on plural rows, and guarded interceptors,
stay walled as later slices.

This slice earned its priority the honest way: writing a real program (a
wave-combat arena) made hand-bumping the scoreboard at every insert/take
site the loudest friction. That same program surfaced two further walls,
now DISENTANGLED (a bisection matters here — one was misdiagnosed at first):

- **`stored` dropped its `|>` tail (FIXED, 690_028).** The `stored` transform
  replaced its site with an EMPTY continuation list, discarding whatever was
  chained after the write — everywhere, not just in spliced bodies. The
  bisection was decisive: `print |> print` chained fine everywhere, only
  `stored |> anything` swallowed the tail. So a `stored` had to be the
  terminal step of any chain. The fix threads the original tail through
  un-marked, and it is CORRECT because the transform runner is a fixed-point
  iterator: a tail that is itself a `stored` re-lowers on the next pass. The
  "watch drops chained writes" framing was a red herring — the splice was
  innocent; the `stored` verb was eating its own continuation.
- **A value-returning impl-flow head with a void `|>` tail leaked an unused
  result (FIXED, 690_029, emitter).** Unmasked by the tail fix: before it, no
  impl flow ever had a value-producing head followed by a void chain, because
  the tail was dropped. A generated event body (the inserted/removed
  interceptor impl flow) whose head is a value-returning `__store_write`
  followed by a second write emitted `const result = …` with no discard —
  `unused local constant`. The gap lived in `emitSubflowContinuationsWithDepth`
  (emitter_helpers.zig): the parent-result discard fired only when the next
  step switched or bind-renamed, never for a plain terminal void step. The fix
  makes that discard unconditional — `_ = &<parent>;` is idempotent, and every
  path here has an in-scope parent const (top-level chains take a different
  emitter, `emitFlow`, and never reach it). So a **two-write interceptor**
  (`removed` doing `alive-1 |> kills+1`) now compiles and both writes land
  (690_029, and the arena scoreboard tracks kills). This was an emitter gap,
  not a store one — it just took a store program to surface it.

The full residue (rulings, stamped theses, gauntlet verdicts, open
queue) lives in `tests/regression/600_STDLIB/690_STORE/DESIGN.md`, which
deletes as pins absorb it. ECT/BLOOM (entity-component-taps) is
superseded by this design; its rings pattern is salvaged as the async
escape from the cascade.
