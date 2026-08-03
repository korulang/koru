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
alias (`enemy` → `pub const Enemy = __KoruStoreRow_enemies`) and makes `take`
mint `<std/store:taken!>` on `Enemy`. The user's discharger consumes
`<std/store:!taken>` — 660_027's base-type-filtered discharge, reused whole.
The obligation *state* is shared and module-qualified; the per-store *type*
carries identity. An early rung-2 spelling kept `taken` local to dodge an
emitter coupling (`writeFieldType` fell back to the phantom's module for the
base type — right for `*Field<std/field:field>`, wrong for `Enemy`/`taken`);
that is REPUDIATED. A second spelling guessed co-location from NAME shape
(`Store` ≈ `store`), which mis-resolved any entity named like a module
(690_037); that is REPUDIATED too. `writeFieldType` now resolves the base
type's home from actual declarations — the host_type_homes registry built
over the program's final items, imported modules included — and qualifies to
the phantom's module only when that module really declares the type. The
take payload carries `module_path` for the user type; cross-module
dischargers name `input:Enemy<std/store:!taken>` (690_036).

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
Field-named interceptors on plural rows, and guarded interceptors, stay
walled as later slices.

**Rung 4 closed its `updated` face (2026-07-17, 690_038/039/040/041):**
`! updated { old, new }` on a plural `new()` is the row write-contract —
the third of Ruling 5's three lifecycle primitives. The payload is the
singleton grammar of 690_003 carried over unchanged (ONE grammar, not a
plural dialect): old/new are the WRITTEN FIELD's images, and the pre-image
read is usage-synthesized per the (c) lean — the `_` discard form
synthesizes no read at all, so a store whose updated arms bind nothing
keeps a write-only write path. Two structural beliefs earned here:

- **The firing site is the apply switch, not the arm payload.** The
  singleton walls `updated` + field watches on one store because its
  updated mode FLIPS the write payload shape; the plural fires updated
  interceptors as host calls inside the write's atomic step (after the
  cell write, before the field arm dispatches), so the contract and the
  subscriptions never contend — updated + watches + guarded reactive
  rules coexist on one plural store (690_041 runs all three). The
  singleton's mixing wall is an artifact of its slice, not doctrine.
- **`updated` observes semantic writes only.** Births arrive whole (O9),
  take is a remove, and take's swap-relocation of the last row is storage
  mechanics — none of them fire it (690_040). The write path — query
  update-where and row-addressed stored — is exactly what does.

The payoff belief, proven by the arena (690_041): a maintained aggregate
riding all three faces is CORRECT BY ARITHMETIC across lifecycle seams —
overkill damage subtracts past zero at update time and the corpse's
removal restores the overshoot, so SUM(hp-of-live-rows) holds at every
settled point with no reconciliation scan. T2's cycle detector already
covered the new face (an updated arm writing its own store rejects
statically) because it scans branch names, not slices — walls built on
the general mechanism extend for free.

An interceptor payload obeys KORU100 like any binding: `! inserted { hp }`
that never reads `hp` is REJECTED — discard with `! inserted _`, or consume
the field (690_032 the wall, 690_033 the used-binding, 690_016/029 corrected
to `_`). This wall has to live in the store transform, and the reason is a
load-bearing gap worth remembering: **`flow_checker`'s KORU100 pass
deliberately skips `[transform]` invocations**, and `std/store:new` is one, so
NOTHING in the normal frontend ever checks the arms attached to it — the store
transplants the payload into a synthesized event input and the emitter then
auto-discards an unused one, so a bound-but-unused field vanished silently.
The store now scans each bound field against the body text. The general shape
(every transform that transplants a bound payload has the same latent hole;
the eventual fix is running the binding-usage check through transforms via the
DFS transform mechanism) is noted but not yet taken — surfaced by a real
program, walled store-side for now.

**Guarded reactive rules on plural stores now work (690_030).** The reactive
surface — `std/store(name) ! field h when <guard> |> …` — carried a `when`
guard on a singleton (690_026) but was walled on a plural store. The wall was
pure deferral: the guard already rides as an arm condition into the apply
switch (producer owns the `if`; cross-store guard reads rewrite to the cells),
so all that was missing was the guard-FALSE completeness. A guarded arm covers
only the true case, so — exactly as the singleton path does — the plural
warms now append an unguarded no-op sibling for that field, completing the
switch. So a plural store can hang a filtered standing rule ("fire only when
an enemy drops to ≤ 0 hp") off its reference face, guard fused into the write
path, not a runtime filter.

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

**A query branch can now TAKE its matched row (690_031) — deletion during a
sweep.** `! query { … } when … |> std/store:take(store[entity])` removes each
matching row ("sweep the dead and despawn them"), the natural bulk operation
the arena reached for. Two pieces closed it. (i) Addressing: inside a query
body a BARE `entity` (as opposed to `entity.field`) is the row cursor itself,
so it rewrites to the qbody's `__koru_qrow` input — previously it leaked as a
stray identifier into generated host code (`.row = entity`, undeclared), the
class of raw-Zig drip the koru-level wall is meant to prevent. (ii) Iteration:
`take` swap-removes, dropping the LAST row into the freed slot, so the sweep
re-checks the same index when `len` shrank instead of advancing past the row
that just moved in — the adversarial order `[5,50,8]` (taking slot 0 swaps 8
back to slot 0) is the case a naive `for i in 0..len` silently skips. A query
whose body leaves `len` unchanged advances normally, so non-mutating queries
are byte-identical. This retires the arena_showcase's GAPS #4 ("query-row
addressing is an enter-triggered standing rule, not a repeatable action"):
it IS a repeatable action now, with correct mutation-during-iteration.

**Owned columns landed and GENERALIZED — B-narrow → any owned type
(2026-07-21).** B-narrow first proved the shape for exactly
`*std/string:String<std/string:instance!>` (690_053 green / 690_054 the wall).
The SAME session then generalized it (690_055 green, `*app/lib/res:Resource<owned!>`):
a column can hold ANY `*mod:Type<state!>` — `*Player<allocated!>`, `*File<open!>`,
`*Resource<owned!>` are the same citizen. The store no longer hardcodes the
std/string tuple; it PARSES the column type (`{type, module, state}`) and
DISCOVERS the canonical discharger from the program (the one void `<!state>`-
consuming event in the type's module), then emits every site — storage cell,
insert-consume phantom, take-reissue phantom, teardown call — from those
discovered values, reusing the `buildKoruModulePath`/`<event>_event.handler`
convention. **Pure `koru_std/store.kz` work — zero compiler/`src/` change.** The
"owned-resource cells" case the disposal repudiation anticipated is now real for
arbitrary resources: the obligation THREADS the store boundary — insert's
synthesized param consumes it (push by move; a value not holding `<state!>` is a
Phantom-state-mismatch rejection), take's payload reissues it per field (pop by
move), and a synthesized teardown flow — appended LAST, so it runs after every
user flow — frees each still-live element through the canonical discharger's
handler. Ambiguous discharge (>1 void `<!state>` consumer, e.g. commit|rollback)
stays the 690_035 drain wall — the caller-driven drain is the later rung. Three
structural beliefs earned:

- **The reissue rides the branch-payload FIELD seeding, not the identity
  payload.** An owned store's `| item` payload is a STRUCT of row fields
  (not `__type_ref`), because both checkers already seed per-field
  obligations on struct branch payloads (`binding.field` keys) and — unlike
  bare-return record fields, which are `not_auto_dischargeable` by design
  (330_096's wall) — branch-payload field obligations auto-discharge. So
  `i.name` auto-frees at scope exit with zero new checker code.
- **Generation-time phantoms must land in the DOT-canonical island.** The
  auto-discharge finder compares canonicalized `module:state` strings
  verbatim; std/string's bare states canonicalize through the module's
  logical dot-name. A slash-spelled generated phantom
  (`std/string:instance!`) misses `free`'s `!instance` and KORU030s in the
  AUTO-DISCHARGE FINDER — `findDisposalEventsForState` compares `module:state`
  strings verbatim (no separator tolerance) — probed in isolation before
  building. This is FINDER-PATH-specific: the EXPLICIT-consume path
  (`validateArgument` → `canonicalizePhantomState` → `lookupModule`) IS
  slash<->dot tolerant, so a user-decl slash-qualified issue AND consume unify
  fine (330_087 green; isolated slash-issue probe compiles). So 330_087 is NOT
  the unbuilt-migration pin — it tests explicit cross-module qualified consume,
  which works; the dot-canonical island requirement stands only because the
  finder path is verbatim. The entity phantoms live in a parallel slash island
  where both sides are source-spelled — the two islands must not be mixed
  per obligation.
- **One obligation surface per store, and no un-commissioned surface half
  works.** The canonical-discharge rule (exactly ONE void `<!instance>`
  consumer on `*String` — the 690_035 ambiguity wall applied at the column
  boundary) is enforced at create; `[entity]`/`[tree]`/char mixes,
  watch/query/interceptors/`stored`, and insert's `| full` (whose early
  return would consume the caller's obligation without keeping the value —
  a silent ownership leak) are all loud later-rung walls, and an owned
  store generates no write surface at all rather than one that moves owned
  pointers without their obligations.

**Owned-column WRITE + watch landed (2026-07-22, 690_062 write / 690_063
watch).** The "an owned store generates no write surface at all" belief above
is now SCOPED, not retired: a **canonical-discharger** owned store gets the
full write+watch surface; only a **drain** store (ambiguous discharger) keeps
none. `stored{}` over an owned column is **discharge-old + consume-new** —
Rust's `vec[i]=x` made koru-explicit: unit-4's apply/write pair generates for
owned stores (gated `!drain_required`, NOT `!has_owned` — the boundary the
build sharpened), the value slot carries the consume-phantom (insert's move-in
reused), and the apply arm reads the OLD pointer, fires the discovered
canonical discharger, then moves the new one in. The eviction is *why* a drain
store is walled: with >1 `<!state>` consumer there is no single discharger to
free the evicted value, so a drain store correctly gets no write surface and
`stored`/`watch` name the drain boundary. `watch` over an owned column fires on
that write — the apply branch payload carries the **bare-borrow** phantom (the
690_060 query projection) and the arm reads the field FRESH from the cell
(690_061's rule), so the subscription borrow-reads the just-written value and
consumes nothing (the store keeps the live `<state!>` it frees at teardown).
The `updated` interceptor over owned stays an honest later rung (it carries TWO
owned images — old and new — of the written field, distinct from removed's
single outgoing borrow). REMOVED over owned IS built (2026-07-22, 690_065): the
`removed` interceptor fires in the take path before the swap-remove,
bare-borrow-reading the outgoing row via the SAME `LC.emit` projection as
`inserted`/`query` — and the finding is that it needed NO new codegen, only an
unwall. `LC.emit` already built the bare-borrow payload for any owned arm field,
and the take proc already fired `removed` with the outgoing copies; the
create-time wall rejected `removed`/`updated` together purely out of caution.
Splitting it (admit `removed`, keep `updated`) is the whole change — react-on-
delete for a reactive todo. Still pure `koru_std/store.kz`, generalized via
`field_owned_info`. This closes Path B's
read→react→write arc: an owned column is now a first-class writable, reactive
citizen. The consume rides the user-facing `__store_write_*` event; the
internal apply proc receives the already-owned plain pointer (the two-hop
phantom placement the build resolved).

**MIXED-field write DE-BUNDLED (2026-07-22, 690_064) — the `captured` model.**
The WRITE rung above bundled all columns into one `__store_write_<s>(row,
field, value_0..n)` event (690_049), unwritten slots riding as typed zeros. A
scalar's zero is cheap; an OWNED slot has NO typed zero (its value is a consumed
obligation), so writing a NON-owned field of a `{label: owned, done: i64}`
store was walled — a `done`-only write couldn't fill `label`'s slot. The fix is
`control.kz`'s `captured` model made concrete: for an owned-containing store the
write is DE-BUNDLED into one TARGETED per-field event `__store_fwrite_<s>_<i>
(row, value)` threading ONLY that field's value. A scalar write never references
an owned sibling's slot or its obligation; the owned field's own write keeps the
consume-phantom on its single `value` (discharge-old in its apply arm, watch off
the fresh cell read). The bundling was signature-only — the apply switch's arm
for field `i` already wrote only cell `i` — so this is a mechanical split, not
new semantics: scalar-only stores keep the untouched bundled 690_049 path, and
the bundled surface stays as the DISCOVERY surface (field order, column types,
watch-splice marker) for owned stores. Distinct `fwrite`/`fapply` prefixes are
load-bearing: store-name discovery strips `__store_apply_`/`__store_write_`, so
a per-field name sharing them would parse as a bogus store. This unblocks a real
reactive todo store — toggle `done` AND rename `label` in one `{owned, scalar}`
table.

The full residue (rulings, stamped theses, gauntlet verdicts, open
queue) lives in `tests/regression/600_STDLIB/690_STORE/DESIGN.md`, which
deletes as pins absorb it. ECT/BLOOM (entity-component-taps) is
superseded by this design; its rings pattern is salvaged as the async
escape from the cascade.

## The ECS story's blocker is the CAPTURE SET, not module resolution (2026-08-03)

Measured rather than assumed, because the standing belief was that module
resolution held the Bevy comparison back. It does not, and has not for a while:

- A store declared in one module and swept-and-written by a system in ANOTHER
  module works today. Stores are linkable from anywhere by bare name, ruled and
  green (690_088). A three-file `world` / `movement` / `main` program with the
  integrate system in its own module compiles and runs correctly.
- The comptime module-mirror wall stands at 41/42, and its ONE red (115_020) is
  not a module defect: it mirrors 690_069, which is deliberately red awaiting
  the row-ordinal spelling ruling. A mirror of a red pin says nothing.

What actually blocks a real workload is one gap, and it is orthogonal to
modules: **a sweep body cannot reach the enclosing tor's INPUT.** `pos += vel *
dt` — the single most common thing an ECS system does — fails with a raw Zig
`use of undeclared identifier 'dt'`. The entry-file twin fails identically, so
this is not a boundary effect (690_243 pins it, red).

The asymmetry is the whole argument. 690_073 is green and captures a mid-chain
BIND into that exact body position. An enclosing tor's input is declared in the
signature — at least as enumerable as a mid-chain bind — and does not arrive.
The machinery is already there and already threaded: `Cap.collectEventInputs`
is called only when the holding flow is a synthesized `__store_sweepbody_`, so
a sweep nested in another sweep sees inputs and a sweep in a user tor does not.
A universal property installed at one of several exits, again.

**The open question is a ruling, not a repair.** T1 (transplant-purity) lists
the legal free names and an event input is not among them, so today's refusal
is T1 working as written. But mid-chain binds are not in that set either and
were admitted anyway, threaded in by value. So: is an enclosing tor's input the
same KIND of enumerable name as a mid-chain bind? If yes, T1 widens by one
member and nothing else moves. Lars owns that.

Independent of the ruling, the failure mode is a defect: a raw host error about
generated code, where a Koru refusal should name `dt` and the rule it broke.

Also standing, and worth stating because it is easy to misread as progress:
the 003_ecs_reactive harness has anchors for Bevy, Flecs, Unity DOTS and a Zig
baseline, and NO Koru entry. The comparison is unmeasured, not unfavourable.
