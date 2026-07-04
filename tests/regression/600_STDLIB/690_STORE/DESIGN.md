# std/store — design walk residue (2026-07-04)

> **DELETE-WHEN-PINNED.** This document is interim scaffolding from a design
> walk (Lars + Claude). Its entire intent migrates into pins in this cluster;
> when the pins carry it, this file dies. Tests are the spec; prose drifts.
> Every claim below is stamped: **GROUNDED** (a test/file read during the walk
> proves the substrate exists), **RULED** (Lars ratified it on the walk),
> **THESIS** (we believe it, nobody has attacked it), **OPEN** (genuine
> undecided design question).
>
> RECONSTRUCTED 2026-07-04 late-night from session context after the working
> tree was emptied by a concurrent session (`rm -rf *`-signature; .git
> survived; tracked files restored via `git restore .`). Content is faithful
> to the pre-wipe document including all rulings through (f) and (i).

## What std/store is

Application state as a first-class reactive substrate: stores are declared
(comptime name + shape) and instantiated (runtime moment), linkable from
anywhere in the program by name. Reads and writes are events; reactivity is
compiled, not subscribed. It is capture's grammar generalized from "one fold's
accumulator" to "the app's spine" — the convergence pinned as the multi-cell
store question in 320_036 and foreseen in the 2026-06-03 capture-dissolution
ruling ("capture may BE the app store").

## Grounded substrate (read during the walk; the machinery already exists)

- **Capture grammar** — seed block / `! as acc` live effect-cell / `| captured r`
  settled continuation: 320_042 (green), incl. opaque source blocks interpreted
  by a projector emitting per-field writes.
- **Cross-nesting write routing** — `captured { oval: outer.oval + ires.ival }`:
  320_036 artifacts green (header prose says RED-frontier; stale — actual.txt
  matches expected.txt with SUCCESS marker).
- **Tap transplantation** — a top-level tap's body is spliced into every
  matching producer site, and the tap's `when` guard is planted on the
  producer's continuation (`koru_std/taps.kz` `wrapContinuation`, ~:766
  ".condition = rewritten_condition"): **the producer owns the `if`; no call
  unless the guard passes.** Binding-rewrite machinery
  (`rewriteStepBindingDeep` etc.) rewrites exactly one name — the tap's own
  binding — to the producer-site binding.
- **Whole-program comptime vision** — `kernel.kz` transforms walk
  `program.items` to find their shape declarations; "the compiler decides
  optimal data layout and iteration strategy" is kernel's stated doctrine;
  magic bindings (`bodies.other`) are established transform vocabulary.
- **Destructure + when** — `| found { name, age: i64 } when age > 40` pinned
  green (020_016; "a when-guard sees destructured names"). Effect-branch
  destructure pinned green (020_018). The composition `! pair { a, b } when
  a > 2` is pinned **020_035 — GREEN (SHOWN 2026-07-04)** after the coverage
  fix (see pin ledger). Compound guards (`and`): **020_036 — GREEN (SHOWN
  2026-07-04)**, closed a real corpus hole (no passing test had ever
  exercised a Koru-level boolean connective).
- **Extent-hosting invocations** — `~koru/vaxis:run(...) ! ready ... ! key k
  when k.ch == 'q' ...` (koru-libs `examples/hello_vaxis.kz`): an invocation
  whose effect branches fire throughout its extent.
- **Cross-module qualified phantoms** — obligations cross module boundaries
  (660_027, landed 2026-07-02): the substrate for store handles carrying
  obligations across the program.
- **Optional resume arms** — `! ?ask i64 -> i64` + producer-side comptime
  presence test `if(ask) | then |> ask(q): a => ... | else => <explicit
  fallback>` (ruled+pinned 2026-07-03 @7c37406a, 400_144/400_146).

## Ruled on this walk

1. **Identity split** — declaration is comptime (name + shape → what makes
   "link anywhere by name" resolvable); instantiation is runtime (the moment a
   store comes alive). RULED.
2. **Plurality-native** — the store IS the table; fields are column
   properties. Scalars are the degenerate case, and stored scalars are often
   really *derived aggregates* (the `entities: i64` counter is `COUNT(*)`).
   RULED.
3. **Two read modes, capture's during/after split** — `watch` is effect-time
   (`!`, fires 0..N while the store lives); snapshot/query-fold reads are
   continuation-time (`|`, settled once). Same reclassification logic as
   capture's `! as` / `| captured` (2026-06-03 ruling, reconfirmed on this
   walk). RULED.
4. **Contract vs subscription split** — effect branches on `create` =
   **interceptors**: schema-level, unconditional, part of the store's
   contract; they keep store state coherent and synchronize stores
   (`! inserted { hp } |> stored { global.total_hp: ... }`). Branches on
   `watch`/`link` = **subscriptions**: consumer-level, many, and their
   placement in the source tree is an ORGANIZATIONAL principle, not a semantic
   one. RULED.
5. **CRUD lifecycle effects are THE primitive** — stores emit
   `inserted` / `updated` / `removed`; everything reactive (maintained
   aggregates, derived columns, filtered views) is the planner COMPILING
   queries down into these same interceptor branches. One primitive, one
   planner. RULED (as direction).
6. **The query block is store's own DSL** — opaque source block
   (captured-style), interpreted by store's projector: path projections
   (`entity.hp`), renames (`enemy_hp: entity.hp` — RHS-as-path is legal here
   precisely because this is NOT core destructure, whose RHS is claimed by
   type assertions per 020_016), mandatory punning (`entity.type` → `type`,
   per the 2026-07-03 punning ruling; a redundant label like `kind:
   entity.kind` is REJECTED). The whole site is rewritten at comptime;
   bindings exist post-rewrite. RULED.
7. **Subscriptions compile tap-style into write sites** — guard included,
   producer owns the `if`. NO runtime subscription registry. If a genuinely
   dynamic subscription construct is ever needed it will be a separate,
   explicitly-runtime thing asked for by name — never a silent fallback.
   RULED.
8. **View directives live in invocation args, not the binding block** —
   ordering etc. (`watch(game, order-by: ..., desc)`): block = what a row
   binds; args = how the view behaves. RULED (lean — revisit if the DSL
   grows).
9. **Stores are SECOND-CLASS — comptime-named, never runtime values.
   RULED 2026-07-04 (Lars lean + design-forced).** No passing stores, no
   store-valued fields, no stores-in-stores. Every load-bearing mechanism
   requires it: watch compilation must know WHICH write path to splice at
   comptime; T4's planner needs the workload closed; cycle rejection needs
   the cascade graph knowable; transplant purity already rejects
   runtime-store references. First-class stores are also the generics
   pressure returning (store-of-store parameterization — refused doctrine).
   Svelte's stores are first-class values and that is exactly why Svelte
   needs a runtime; second-class-ness IS the zero-cost. COMPOSITION
   INSTEAD: row handles as plain data across stores (foreign keys — rows
   reference rows), cross-store coherence via interceptors. The core
   concept stays strong enough that higher-order combining is never
   needed.

## Theses — attack these

- **T1 · Transplant-purity is decidable.** A watch body may live anywhere in
  the tree iff its free names ⊆ {its query-block bindings} ∪ {comptime-known
  names: module decls, qualified calls, other stores}. Violation = fantastic
  compile error. Claimed reason it works: Koru flows have explicit enumerable
  bindings; closures in other languages capture ambient environment
  invisibly, making this check impossible there. (See adversary verdicts —
  the check is a wall to BUILD, not one more brick; it lives IN the store
  transform per the 2026-07-04 ruling under (a).)
- **T2 · Cascade cycles are a compile-time diagnostic.** Interceptors writing
  other stores form a comptime-visible graph; cycles are rejected with the
  cycle named. (See gauntlet 2: graph must be FIELD-level and must close over
  watch-triggered writes, not just create-interceptors.)
- **T3 · Maintained aggregates are interceptor compilation.** `SUM(hp) WHERE
  type == ENEMY` compiles to delta updates at write sites: +hp on view-enter,
  -hp on view-leave, difference on in-place change. Enter/leave is the delta
  algebra, not just UI vocabulary. One-shot snapshot folds remain legal.
  (Adversary verdicts: holds for linear aggregates only — tiers needed.)
- **T4 · Layout is the closure of the queries.** Projections across all
  watches/queries → which columns exist (SoA; unprojected fields get no
  column in the reactive layout); predicates → which filtered views/indexes
  are maintained (`alive` → sparse membership set); per-query renames → named
  consts off planned columns. The whole workload is comptime-certain — the
  input a DB planner never gets. (Gauntlet 2: contradicts ruling 2 for
  SERIALIZATION — declared-field column guarantee needed.)
- **T5 · The no-silent-perf boundary.** Projections/layout choices are pure
  wins → kernel dispensation ("compiler decides"). Predicate-MAINTAINED views
  move cost to write sites → need an explicit home (declaration or
  annotation), else a watch added far away silently slows writes; brushes the
  no-silent-performance-degradation ruling. Where exactly the line sits is
  part thesis, part open. (Adversary round 1: T4/T5 internally inconsistent
  on `alive → sparse set`; projection-vs-projection layout CONTENTION is a
  third axis neither names.)
- **T6 · Row identity via phantom obligation.** Insert returns a row handle;
  `take` adds `<row!>`-style obligations for spawn/despawn discipline — an
  entity you take cannot be leaked, checked at compile time. (No ECS has
  this.) Now largely a corollary of ruling 5 + the O2 four-heads ruling.
- **T7 · Isolation via phantom cardinality.** One linear writer handle, many
  free reader handles = data races unrepresentable; cashes the no-threads
  tenet's pending thesis ("cells = the only mutable things → the
  parallel-handler contract is one phantom away"). Watch bodies inherit the
  write site's execution contract (per-event contract ruling) — the sync
  story is separable from everything above.
- **T8 · The storage backend is DI-able via optional resume arms.** The store
  declares `! ?fetch` / `! ?persist` (optional resume arms, ruled+pinned
  2026-07-03 @7c37406a). Consumer installs handlers → the store fronts SQLite
  (koru-libs `*Connection<opened!>` — the assimilate bed), a network cache,
  anything. Nobody installs them → presence resolves to `| else` at comptime
  and the planner's in-memory layout inlines: **statically-resolved DI, zero
  cost when unused** (runtime algebraic-effect handlers do this dynamically;
  the presence ruling makes it static). BOUNDARY: coherence of all reactive
  machinery requires the store to be the SOLE write path — backend arms are
  called BY the store, so deltas see every write. External mutation of the
  backing storage is out-of-model by design (see O8).

## Open questions

- **O1 · Fire vocabulary for query watches** — per-row enter / leave /
  changed vs batch view-changed; branch names (`! enter { … }`) vs args?
  Reactive UI needs enter AND leave. GAUNTLET 2: the ruling must include the
  TRANSITION MECHANISM (evaluate the guard against pre- and post-write row
  images; dispatch enter on false→true membership, leave on true→false) and
  a `changed` vocabulary (in-view row, other field written). Also coupled to
  O3 via attach/backfill — though rung-one top-level born-empty stores have
  NO attach moment and NO backfill problem.
- **O2 · Row addressing for writes — RULED 2026-07-04 (Lars, "we can
  probably DO this"): ONE LVALUE PATH GRAMMAR, FOUR ADDRESSING HEADS.**
  (1) insert returns the handle (`insert(game) { ... } | row r`) — primary
  identity, store-name-synthesized, NOT obligated by default; (2) handle
  addressing `game[r].hp` (indexed-lvalue precedent: `captured { g[a][b]:
  v }`, 320_057 green); (3) declared keys — a field marked key at create →
  `game[id: 7].hp`, key index = a DECLARED cost (lands on ruling (g));
  (4) query-row addressing — the bound row is a head: `stored {
  entity.hp: ... }` under a query branch = UPDATE WHERE,
  `take(game[entity])` = DELETE WHERE. Singleton `game.hp` = the grammar
  with the head elided (one-row store). POSITIONAL INDEX IS NOT IDENTITY
  — demoted to query ordering; it also legalizes swap-remove. Verb
  dialect: keep insert/take (lifecycle-anchored: inserted/removed;
  `pop` falsely implies position) but reads/borrows use the same heads.
  Earlier partial ruling, still standing — **move semantics via `take`** —
  `take` extracts the row WITH ownership: compiles as the `removed`
  lifecycle event WITH a synthesized obligation attached (delta machinery
  stays coherent for free — a taken row exits views/aggregates as an
  ordinary removal). Obligation phantom is name-synthesized from the store
  declaration (`<game:item!>`-shaped) — the shipped qualified-phantom
  collections pattern (660_027), NO generics exposed. Disposal verb
  undesigned (`give-back` floated). (`take` name provisional.)
- **O3 · Store extent** — module-top-level `~create` (program-long, like
  `~capture`) vs mid-flow creation with `*Store<store!>` obligation-carried
  extent. Likely both, same construct. Interceptors live for the extent.
  NOTE: comptime wiring is ATEMPORAL — a mid-flow watch is wired into all
  write sites regardless of lexical position; "attach moment" semantics only
  bite mid-flow extents.
- **O4 · `when` vs `where`** — the query DSL could say `where`, but two
  selection words need earning; lean `when` everywhere.
- **O5 · Comptime-generated benchmarking as user-facing feature** — the
  planner's workload knowledge reused to emit per-layout benchmark harnesses
  (std/benchmarking exists as substrate). Aspirational.
- **O6 · Layout override annotations** — explicit user override of planner
  layout (annotations are open metadata, ruled 2026-06). Also a candidate
  home for T5's explicit write-cost declarations.
- **O7 · Multithreaded write sites** — what synchronization the store's
  write path needs under the per-event execution-contract model. The
  isolation half; deliberately deferred. (See O11 RINGS for the deferred-
  work half.)
- **O8 · External-mutation sync** — a DI'd backend (T8) mutated from outside
  the program (another process writing the SQLite file) is invisible to the
  delta machinery. If ever supported, it is a separate EXPLICIT verb
  (rescan → diff → synthesized enter/leave), never a silent capability.
  Candidate refusal: never support it; the store owns its data.
- **O9 · Does the creation seed fire watches/interceptors?** Surfaced by
  the pins (2026-07-04 QA): 690_001/003/004's expected.txt all embed the
  answer NO. LEAN: birth-is-not-a-write — creation is birth, not change;
  watches observe writes; also keeps top-level stores consistent with the
  no-attach-moment story. REFINEMENT (adversary 2b, adopted): birth performs
  the MEMORY store of the seed but suppresses the EVENT — else the first
  delta's `old` reads garbage. PENDING Lars ratification.
- **O9b · Does row INSERT fire per-field watches?** Surfaced writing
  690_008: LEAN NO — a field watch observes CHANGE to an existing row's
  field; a born row arrives whole and announces itself via `inserted` (and
  query enter — NOTE: forward-references O1's still-open vocabulary).
  Sibling of O9. PENDING ratification.
- **O10 · Allocation policy — RULED-LEAN 2026-07-04 (Lars: game-dev perf
  focus in everything).** (i) CAPACITY IS DECLARED at create — fixed
  static memory, SoA columns as fixed arrays, the MAX_ENTITIES pool
  idiom; silent autogrow is a silent realloc = the exact shape the
  no-silent-perf ruling kills. Autogrow = EXPLICIT opt-in at the
  declaration only. (ii) EXHAUSTION IS A BRANCH: fixed-mode insert grows
  a `| full` sibling (or panic-branch `| ?!full`, optional-but-loud) —
  handled or explicitly declined, never a hidden grow, never a bare
  crash. (iii) THE MEMORY CONTRACT is ruled, the mechanism is the
  planner's: dense iteration, O(1) insert/take, handles stable across
  other rows' removal (sparse-set vs slot-freelist = planner per
  workload; swap-remove legal because positional index is not identity).
  (iv) HANDLE-SAFETY FLOOR: generational check per access (one compare)
  as the safe default; phantom-proven elision where the checker
  establishes no-stale — THESIS, same floor-then-prove-away arc as the
  concurrency lock and escape-driven stack alloc. Owned (`take`) handles
  are fully compiler-tracked; the generation guard covers plain handles
  that outlive another's take. REFINEMENT (adversary 1b, adopted): the
  true silent-wrong-answer risk is the ELISION thesis (a wrong no-stale
  proof skips the generation compare → silently returns another row's
  data), not the loud panic path; the panic path still needs its
  failure-mode spelling (`| stale` branch vs `?!`-panic). GAUNTLET 2:
  handle stability across GROWTH (realloc moves SoA columns) is unruled,
  and growth is unclassified w.r.t. the atomicity unit — the web case's
  escape valve is named but not designed. CONVERGENCE NOTE:
  declared-capacity SoA store + delta maintenance = the std/field
  "castles" dense-buffer initiative growing its reactive half.

## Adversary verdicts (2026-07-04 — three sealed reviews, captain-verified)

Three blind adversarial reviews (transplant mechanics / planner+perf /
reactive semantics) attacked the theses. Key citations re-verified by the
captain against source before recording. Outcomes:

- **T1 — WOUNDED, cost was fiction.** No free-name checker exists anywhere in
  `src/` (flow_checker.zig:8-27 does when-exhaustiveness, coverage, and
  UNUSED-binding KORU100 — the reverse direction; verified by grep). Guards
  and bodies are today STRINGS textually rewritten
  (`rewriteBindingInValue`), not ASTs. Transplant-purity remains plausible
  but is a wall to BUILD, materially harder than "one more wall".
- **T1-adjacent, VERIFIED — the obligation wall:** every spliced body gets
  `@scope` (taps.kz:714-717 "can observe but cannot satisfy outer
  obligations"; enforced in phantom_semantic_checker inheritWithScope).
  Watch bodies are OBSERVE-ONLY w.r.t. obligations live at the write site.
  → RULED under (a).
- **T1-adjacent, VERIFIED — module resolution:** the splice never rewrites
  `inv.path`; unqualified names in a transplanted body resolve against the
  WRITE SITE's module, not the declaration site's. Store transform must
  qualify-at-splice or reject unqualified names.
- **LATENT TAPS BUG (floated, unpinned):** `_tap_N` binding synthesis hashes
  branch+indent+step-path but omits `tap_salt` (taps.kz:604-615) — two
  different taps landing on same-shaped sites can silently collide bindings.
  Needs a repro pin before any fix.
- **T2 — NEEDS-RULING, leans breaks-if-naive.** Graph must be FIELD-level
  (store-level can't express own-store-other-field writes). `when`-guarded
  edges make the static graph an over-approximation (guard disjointness
  undecidable) — precedent (module_resolver import cycles) is the EASY
  unconditional case. Convergent self-writes (clamp `x = min(x,10)`) need a
  carve-out (compiler precedent: 1-cycle special case,
  emitter_helpers.zig:287). ALSO: cyclicity is the wrong sole check — deep
  ACYCLIC cascades multiply code size (see splice topology, now ruled (f)).
- **T3 — BREAKS as universal claim.** Delta algebra covers linear aggregates
  (SUM/COUNT) only. MIN/MAX need auxiliary structure or rescan-on-leave;
  COUNT DISTINCT needs refcounts; FLOAT sums drift unboundedly under +x/−x
  (KORU047-class silent-wrong-answer). → Aggregate TIERS needed:
  delta-exact / auxiliary-structure / can't-prove-exact-=-annotate-or-error.
  ALSO unstated: in-place-change deltas require OLD value → every update is
  read-modify-write and the lifecycle payload is `{old, new}` — must be
  ruled as the write contract (see (c) lean). ALSO: "comptime-certain"
  conflated delta SHAPE (comptime) with delta VALUES (runtime).
- **T4/T5 — INTERNAL INCONSISTENCY + missing axis.** T4 cites `alive →
  sparse membership set` as free layout; T5 classifies predicate-maintained
  views as needing an explicit home. Same construct, both buckets — unruled.
  Missing third axis: projection-vs-projection LAYOUT CONTENTION (full-row
  serialization watch wants AoS; hot aggregate wants SoA column — planner
  serving one injects gather cost into the other, invisible in either's
  source).
- **SPLICE TOPOLOGY — now RULED, see (f).** The tap mechanism deep-clones
  the body PER MATCHING CALL-SITE OCCURRENCE (cloneContinuationsDeep per
  Flow; no dedup) → naive store = O(write-sites × watchers) cloned bodies
  (40 sites × 12 watches = 480 copies), plus global blast radius: one watch
  added anywhere re-codegens every write site (collides with no-silent-perf
  doctrine; benchmarks don't survive unrelated commits).
- **HELD:** tree-shaped splice generalizes (full subtrees transplant
  intact); producer-owns-guard confirmed at taps.kz:766-777; whole-program
  visibility is Koru's stated model (dead_strip.zig:11-13), so T4 adds no
  separate-compilation gap; ECS-fragmentation risk does NOT transfer while
  rows stay fixed-schema; atemporal comptime wiring means rung-one top-level
  empty-at-birth stores have NO attach/backfill problem (O1×O3 coupling
  bites only mid-flow extents).

## Gauntlet 2 verdicts (2026-07-04 — five banshees: 3 showcases + 2 adversaries)

Three showcase programs (game arena, todo web app, SQLite ORM — the first
two preserved in `showcases/`, harness-invisible: no NNN prefix/marker)
plus two adversaries attacked the post-round-one rulings. Findings ranked
by CONVERGENCE — how many independent lines of attack hit the same root:

- **×3 → (f) IS THE MASTER RULING (now RULED, see queue).** The centralizing
  per-store subflow is independently required by: the atomicity lock (needs
  one body to wrap), code size (needs one body to splice), and T8 (the
  `*Connection<opened!>` can only be closed over if storage arms compile
  into ONE body — under per-site splicing, transplant purity rejects the
  connection like `ctx` in 690_006).
- **×3 → DISPOSAL VERB blocks every delete flow.** Todo delete, ORM evict,
  arena death all stalled on it; 690_007 rejects the naive shape by
  design. Candidate spelling floated by two agents: `give-back`, taking
  the item value; corpus discharge idiom = void call in consume-position
  (`std/list:free`, `Connection:close`).
- **×2 → TRANSACTION/BATCH ENVELOPE (now NEED-RULED, see (i)).** (a)
  Multi-field one-action UI writes and undo-step boundaries need it; (b) the
  SYMMETRIC two-store exchange (item swap, trade) has no directional cascade
  shape — the only atomicity tool ((h): make it one cascade) is exactly the
  shape T2 rejects as a cycle. Compound break: neither ruling alone, their
  interaction. A future construct must also face MULTI-STORE LOCK ORDERING.
- **×2 → CROSS-STORE REACTIVE CLOSURE.** A query guard referencing
  another store's field (`when app.filter == 0`) compiles taps only at
  the ROW store's write sites — writing the filter fires NOTHING (the
  todo app's filter tabs are decorative; reactive joins have the same
  root). Fix is latent in T4: the guard's free names are comptime-visible
  → taps follow the guard's full free-name CLOSURE, pricing the
  re-evaluation cost at a declaration per (g).
- **QUERY TEMPORALITY (game showcase, the semantic surprise).** Under
  atemporal wiring a query is a STANDING RULE (program-lifetime,
  enter-triggered) — there is NO repeatable/imperative form, so "run this
  sweep now" (per-tick UPDATE WHERE) is inexpressible; the arena routed
  repeatable damage through handles instead. ALSO: 690_005 vs 690_008
  jointly embed an unstated answer about when a post-insert-declared
  query applies to pre-existing rows — 690_008's expected.txt carries an
  ambiguity about WHEN the sweep fires. CANDIDATE RESOLUTION now in O13's
  stripe ruling: `stripe(game)` as the scan-driven firing mode.
- **ITERATION CONTRACT (adversary 1a).** DELETE WHERE (O2) × swap-remove
  (O10.iii) = the classic iterate-and-remove bug; the two rulings were
  never checked against each other. Needs: deferred compaction or
  removes-apply-after-scan.
- **T2 SCOPE GAP.** The cycle graph covers create-interceptors only;
  watch-triggered writes are legal and outside it — `watch(A)→write B,
  watch(B)→write A` is an unchecked live cycle. The graph must close over
  ALL reactive edges.
- **KEY COLLISION (adversary 1c).** Total silence; map precedent (silent
  overwrite) would INVALIDATE the prior row's handle through ordinary
  control flow — manufactured staleness. `key`'s SQL connotation demands
  reject-or-branch.
- **HANDLE GAPS (game showcase #7/#9/#10).** A plain (un-taken) handle
  has NO type spelling for leaving its originating chain (subflow param,
  stored in a list) — games need this immediately; no liveness-check
  construct exists; and the no-join-after-branch parser reality (KORU010)
  makes branch-heavy game logic duplicate code or extract subflows it
  cannot yet parameterize.
- **VOCABULARY UNIFICATION (adversary 2a).** `! hp h` (field-named) vs
  `! updated { old, new }` (lifecycle) — two surface grammars, desugaring
  unstated, multi-field `updated` payload undefined (690_003 masked by
  single-field degeneracy). Plural CRUD interceptors also lack row/
  sibling-field context (no `entity`-style binding outside query).
- **T8 REFINEMENTS (ORM showcase).** Arm shape: corpus grounds only
  SCALAR resumes — void arms with side-effecting bodies are the grounded
  alternative; needs ruling. Firing granularity (fetch-once-at-init /
  persist-per-write) unruled. HYDRATION BYPASS needed: fetch→insert
  re-fires persist (write-back loop) — sibling of O9 at the persistence
  layer. External work item: koru-libs sqlite3 has NO parameterized
  mutation exec (string-built SQL) — real library gap regardless of store.
- **REFUSAL TO ENCODE (both adversaries + todo):** mount/unmount-scoped
  per-widget subscriptions. Watches are program-lifetime; the common case
  is a boolean mode-field guard; true dynamic attach/detach is a separate
  named construct if ever — a documented wall, not silence.
- **SECOND-CLASS ESCAPE HATCH (adversary 4):** reusable subsystems (N
  per-player inventories from one library definition) are answered by
  neither foreign keys nor copy-paste — candidate: store declarations as
  COMPTIME-TEMPLATED CODEGEN units minting N comptime-named stores
  ("comptime codegen library instead of generics", standing doctrine).
  Rule in or out explicitly.
- **NEW OPEN — SERIALIZATION (adversary 1 §6):** ruling 2 ("fields are
  columns") vs T4 ("unprojected fields get no column") contradict;
  save-game projects EVERYTHING. Needs: declared-field column guarantee +
  possibly a whole-row/whole-store fifth addressing head, as an explicit
  escape-hatch verb (colliding with ruling 9 by design).
- **TIME (adversary 1 §1):** debounce/throttle/frame-batching — candidate
  REFUSAL ("the store reacts to writes, not clocks; compose with a
  tick-writer store") EXCEPT batching, which the (i) envelope covers.
  HISTORY/undo = opt-in at create (`history:`-style declared cost) + the
  envelope; not alien, not designed.
- **WHAT HELD ACROSS ALL FIVE:** the spine — compiled subscriptions, sole
  write path, four heads, second-class stores, interceptor contract,
  derived-aggregates-as-fields ("arguably better than Svelte's at the
  primitive level" — todo verdict). Failures cluster on few roots; none
  touched the core claims.

## ECT/BLOOM reconciliation (2026-07-04 — scout verdict: store SUPERSEDES)

The prior Entity-Component-Taps design (blog `entity-component-taps`,
draft:true/index-invisible; `/platform/bloom` page LIVE and stale —
Lars's call: repurpose toward store or retire) is superseded: its central
mechanism is the naive splice topology ruling (f) exists to fix (ECT
never diagnosed it); its `?changed` arms became the optional-arms
language ruling; its archetype SoA became T4; its bare EntityId became
obligated handles; its `*Entity<a+b>` syntax exists in the corpus only as
a comment citing it as a counter-example. SALVAGE folded as new opens:

- **O11 · RINGS — the async escape from the cascade.** ECT's one move the
  store lacks: a watch/interceptor body pushes a struct onto a lock-free
  MPMC ring (koru_std/rings.kz EXISTS); a consumer thread/extent drains
  it. Candidate mechanism for: heavy work off the write path (render,
  audio), async write-backs (gauntlet-2 §2), frame-batched consumption —
  all without violating the (h) atomicity unit (the push is cheap and
  inline; the work is elsewhere). O7's deferred half now has a shape.
- **O12 · Self-observability.** The store's own machinery (query fires,
  watch fires, cascade depth) should be tappable/instrumentable — ECT
  tapped its own for_each for profiling; the store should be inspectable
  by the same mechanism it is built from.
- **O13 · Dynamic capability sets — RULED 2026-07-04 (Lars): NO
  ARCHETYPES; capability is DATA, never schema membership.** The stripe
  argument: in a fixed-schema SoA store with the workload comptime-known,
  the archetype's two jobs dissolve — (1) component-presence is just a
  predicate column, handled per-query by the planner's existing choice
  (in-loop branch when selective-high vs maintained sparse view when
  selective-low; the archetype is a COARSER global version of the same
  trade, paid for with migration+fragmentation); (2) FUSION: compiled
  subscriptions mean ONE stripe pass serves the ENTIRE workload — S
  archetype systems = S bandwidth-bound passes over overlapping columns,
  one fused stripe = one corpus read regardless of query count. No
  runtime-registered system can fuse; compiled ones do for free. Entity
  gains a component = a presence-bit write firing ordinary deltas, never
  an O(C) row migration. Prior-art support: the sparse-set camp (EnTT)
  vs archetypes debate, PLUS fusion which neither camp has. UNVERIFIED
  perf claim by design — pin as a koru-benchmarks entry
  (stripe-fused-taps vs archetype ECS) the day the store runs; napkin: 1M
  entities × 64B = one fused stripe ≈ low-ms at memory bandwidth.
  CONSEQUENCE for (l-new) query temporality: the imperative sweep IS the
  stripe — `stripe(game)` runs the standing compiled rules across the
  corpus once, now; event-driven (write) and scan-driven (stripe) are two
  firing modes of ONE query definition; per-frame stripe = the natural
  frame-batch boundary. (ECT's execution model was literally named
  "Stripe" — right iteration instinct, wrong subscription substrate.)

## Ruling queue (for Lars, consolidated — RE-RANKED by gauntlet-2 convergence)

**(i) TRANSACTION ENVELOPE — NEED RULED 2026-07-04 (Lars): multi-write
atomic grouping must exist; solve with minimal DX and let static analysis
erase the problem family. LEAN (Claude, Lars-endorsed direction): THE
CHAIN IS THE ENVELOPE** — consecutive store-writes in one flow chain are
one atomic unit (cascades per-write, watch dispatch deferred to chain
end); separate top-level statements stay separate units; symmetric
two-store exchange = one flow writing both stores in one chain (no mutual
interceptors — T2 stays intact); lock set per chain is comptime-known →
acquire in store-declaration order → deadlock impossible by construction;
single-write chains degenerate to (h) exactly. No transaction keyword
ever exists. CAPTURED sub-questions: does the envelope span non-store
chain steps (lean: maximal run of store writes); cross-flow grouping
(undo user-actions) may later want an explicit block escape — not rung 2.

Priority order after both gauntlets: **(f) RULED** → **(i) need-ruled,
chain-envelope lean** → **(j-new) cross-store reactive closure** →
**(k-new) disposal verb** → **(l-new) query temporality (stripe candidate
in O13)** → (h) upgraded to rung-3-blocking (view-of-view) → then the
original letters and the cheap-pin tail (key spelling, capacity spelling,
`| full` coverage convention, plural CRUD payloads, bool-literal guards,
plain-handle type, hydration bypass, key collision, iteration contract,
growth stability, T2 scope, vocabulary unification, serialization
O-number, mount/unmount refusal paragraph, store-minting codegen).

(a) ~~Ratify observe-only watch bodies?~~ **RULED 2026-07-04 (Lars): YES for
    taps — observation must be obligation-neutral (adding/removing an
    observer never changes program correctness); `@scope` no-escape is
    conceptually right. Store subscriptions LEAN same scoping (a watch sees,
    never owns); the owning path is `take` (see O2). Transplant-purity check
    lives IN the store transform (rewrite-time, pre-checker, koru-level
    diagnostic) — no new Zig checker pass required for store; the general
    free-name hole remains open as toolchain work.**
(b) Aggregate tiers — direction? (float-maintained sums: annotate or error?)
(c) RMW + `{old,new}` lifecycle payload as THE write contract?
    **LEAN 2026-07-04 (Lars): usage-synthesized** — the transform inspects
    the effect-branch destructures; the old-image read is synthesized ONLY
    where some body binds it (projector pattern, usage-driven). No
    old-binding anywhere → writes stay write-only. Synthesized reads happen
    inside the write's critical section (see h) → race-free by
    construction. Caveat: planner-generated aggregate maintenance binds old
    invisibly → the T5 explicit-home question, tracked at (b)/(g).
(d) Cycle policy: field-level graph, static-reject + escape annotation
    (`@converges` candidate for clamp shapes), carve-outs; cascade-depth
    budget? Graph must close over watch-triggered writes (gauntlet 2).
(e) Pin the `_tap_N` salt-omission collision as a red taps test?
(f) ~~Splice topology?~~ **RULED 2026-07-04 (Lars): ONE CENTRALIZING
    WRITE-SUBFLOW PER STORE.** All writes call into the store's generated
    subflow; watches/interceptors/guards/storage-arms splice there ONCE;
    the atomicity lock and T8 backend cells live in that body. Lars notes
    the inline-vs-call perf difference is likely negligible either way —
    treat as a benchmarkable assumption, not a proven fact.
(g) T4/T5 boundary: which bucket is `alive → sparse set`; layout-contention
    rule (contention = compile error demanding explicit annotation?)
(h) Firing order: one deterministic stratification rule for hand-written +
    planner-generated interceptors (prior art: DBSP strata, Solid topo).
    **LEAN 2026-07-04 (Lars): NO TORN STATE as a headline guarantee** —
    writes INTERLEAVE, never overlap; the atomicity unit is write + full
    cascade; no watch ever observes mid-cascade state. Floor: one
    over-protective lock in the store's centralizing subflow (trivial to
    place given (f)) — SAFE from self-deadlock precisely because T2 rejects
    same-store cascade cycles statically. Ladder: lock elided when the
    per-event execution-contract graph proves no parallel handler reaches
    the store's write sites (contracts ARE the threading proof — the
    escape-driven-stack-alloc arc repeated); finer-grained parallelism only
    where provable (guard satisfiability / dynamic row aliasing =
    the honest uncertainty, rung four). GAUNTLET 2 UPGRADE: stratification
    blocks view-of-view (aggregate-of-aggregate) — rung-3-blocking.
    REC (pending): planner-generated maintenance fires FIRST, then user
    interceptors in declaration order, depth-first.

## The perf north star — ecs_bench_suite mapping (2026-07-05, Lars-directed)

Cloned to ~/src/ecs_bench_suite (rust-gamedev, ARCHIVED — their retro:
"speed is only one aspect"; we take the PROTOCOL as donor and the
workloads as gap-flags, instrument never destination). Site integration:
benchmarks.json already has the shape (per-entry ABSENT markers, vendored
corpus convention, koru-benchmarks feeds the live board — the Osprey
compute-kernels category, other session's machinery; coordinate, don't
collide). Target: an `ecs-store` category, seven entries, mostly ABSENT
day one — the AoC pattern pointed at performance.

- **ONE-TO-ONE (ballpark entries):** Simple Insert (10k×4-component
  inserts → rung-2 insert path + pool + `| full`); Simple Iter (pos+=vel
  → standing query + stripe — the SINGLE-query base case where fusion
  gives no edge: the baseline we must MATCH, and (l)/iteration-contract's
  falsifier); Heavy Compute (mat4x4 invert ×100 → compute-bound stripe;
  mostly Zig codegen, kernels board already at C-parity; mat4x4 column
  substrate grounded via 2-D cells 320_057).
- **DISSOLVED-BY-DESIGN (category-boundary entries — the drag-race
  lesson applies at full force; label or die):** Fragmented Iter
  (measures archetype fragmentation — a cost the no-archetype ruling
  refuses to have; show the same workload without the disease, labeled a
  different category, NEVER quoted as a win); Add/Remove Component
  (measures archetype MIGRATION; ours is a presence-bit flip per O13 —
  same workload name, categorically different operation). These two are
  where the central refusal gets validated or embarrassed.
- **GAP-NAMERS (honest-ABSENT until rungs land):** System Scheduling
  (T7/O7 outer parallelism from disjointness proofs — rung 4; ALSO the
  fusion stress case: their three systems overlap on C, naive fusion
  illegal → forces stratification (h)); Serialize (the whole-row/
  serialization hole from gauntlet 2 — still needs its O-number).

## Rung ladder (build order, each rung shippable)

1. **Scalar singleton store** — `create` / `link` / `stored` / scalar `watch`;
   compiled broadcast (tap machinery, via the (f) centralizing subflow);
   transplant-purity reject pin (MUST_FAIL); interceptors on create.
2. **Plurality** — rows, CRUD lifecycle effects, row identity (O2 four-heads),
   query-watch with destructure+when, the (i) chain-envelope.
3. **The planner** — projections → layout, maintained aggregates/views (T3,
   T4, T5 boundary), stratified firing (h).
4. **Isolation** — writer/reader phantoms, multithreaded write sites (T7,
   O7, O11 rings).

## Pin ledger (grows until this file dies)

- 020_035_destructure_effect_branch_when_guard — destructure + when on an
  effect branch. **GREEN (SHOWN 2026-07-04).** First draft had only the
  guarded handler and was correctly rejected KORU022 — a required `!`
  branch with only when-guarded handlers is incomplete coverage (ruled,
  210_085); fixed with the unguarded-fallback sibling (400_089's rescue
  shape). Substrate for the store query guard.
- 020_036_destructure_when_guard_boolean_and — compound guard (`and` over
  destructured names). **GREEN (SHOWN 2026-07-04).** Parser plumbing
  existed (expression_parser.zig) but ZERO corpus test exercised a
  Koru-level boolean connective before this pin. Grounds 690_005's
  compound query guard.
- 690_001_store_create_stored_watch — hello-store: create/stored/watch,
  singleton. MUST_RUN, aspirational RED (rung 1).
- 690_002_store_watch_guard_producer_if — `when` compiled into the write
  path. MUST_RUN, aspirational RED (rung 1).
- 690_003_store_interceptor_cross_store_sync — interceptors as contract;
  `updated { old, new }` usage-synthesized payload ((c) lean). MUST_RUN,
  aspirational RED (rung 1).
- 690_004_store_no_torn_state — write+cascade atomicity, watches observe
  settled state only ((h) lean). MUST_RUN, aspirational RED (rung 1).
- 690_005_store_plural_query_watch — plurality, query DSL (path projection,
  genuine rename, pun, compound when). `insert` verb and `query` branch
  name PROVISIONAL (O2/O1). MUST_RUN, aspirational RED (rung 2).
- 690_006_store_reject_watch_body_ambient_context — transplant-purity
  rejection, koru-level diagnostic. MUST_FAIL (designed negative).
  expected_error.txt is DOCUMENTARY (harness checks EXPECT CONTAINS lines
  when both are present).
- 690_007_store_reject_take_leak — taken row cannot be leaked (synthesized
  `<game:item!>` obligation). REWRITTEN 2026-07-04 to handle addressing
  (`insert | row r`, `take(game[r])`) per the four-heads ruling — the
  original `index: 0` spelling was incoherent (position ≠ identity).
  MUST_FAIL (designed negative). Disposal verb undesigned.
- 690_008_store_update_where — query-row addressing head: `stored {
  entity.hp: ... }` under a query branch = UPDATE WHERE. MUST_RUN,
  aspirational RED (rung 2). NOTE (gauntlet 2): carries the query-
  temporality ambiguity — reframe when (l) is ruled. Deferred pending O10
  ratification: the `| full` fixed-capacity insert pin.

All seven original 690 pins RAN 2026-07-04 (QA pass): every one fails at
Stage A — `KORU002: module not found: 'std/store'` — honest red. Mechanism
note (corrected after tracing regression_lib.sh): the MUST_FAILs stay red
via STAGE mismatch (EXPECT declares BACKEND_COMPILE_ERROR; the actual
failure is frontend, so CONTAINS lines are never evaluated) — coarser than
content mismatch, same no-lying-green outcome. Convention notes: (1)
BACKEND_COMPILE_ERROR-for-Stage-C-rejections follows 400_149/330_053
precedent (harness treats it identically to BACKEND_RUNTIME_ERROR); (2)
expected_error.txt files on the two MUST_FAILs are DOCUMENTARY.
