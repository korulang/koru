---
type: belief
id: frag-type-system-design
provenance: introduced by 997f0ae8 — test(types): un-park the type corpus — 24 tests, honest-red board for the registry design. Evolved 2026-08-13 with the registry-first rulings, after the corpus-purity sweep (2026-08-12) settled that the pure surface is the surface and the type-system design walk converged on: types are data, the registry is the type system, sums need no generics
ts: 2026-08-13
---

# The type system — registry, stamped names, comprehensions (design belief)

Koru's type system is grown, not decreed: a **dumb, metadata-loaded
registry** in the gray zone (a koru_std module the compiler relies on —
list.kz style: Koru surface tors over a Zig storage core, threaded
through CompilerContext because *the compiler itself reads it* — the
criterion that distinguishes it from the tap-registry anti-pattern),
fed by **plural, opinionated, userspace generation libraries** of which
`std/types` is merely the first. Ruled across the 2026-07-06/07 walk:

- **Stamped names carry monomorphized identity**: `#` in a type name
  (`list#i64`, `box#EmailAddress`) marks "a type parameter lives here"
  by convention — no parametric grammar (generics stay a comptime
  codegen library, ruled 2026-06-13). Erasure decides the placement:
  phantoms erase at emission, layout-determining identity cannot, so it
  lives in the name — the part that survives. The deterministic name IS
  the alias/identity, dissolving `~type(X = ...)` and giving the
  registry breakdowns (signature / capture cell / dispatch / nesting) a
  spelling. Composition grouping (`wrapper#(box#i64)`) deliberately
  unruled — pinned as a demand marker (030_112).
- **The registry is instantiable, not singleton**: same table machinery
  can be privately owned by a library (where a relocated tap registry
  belongs). The compiler's instance is special only because compiler.kz
  threads it. Entries are name-keyed and reference OTHER ENTRIES, not
  host strings — primitives are seed entries; Zig spellings appear only
  at the emission boundary. Registration surface: tiny verb set
  (register/lookup/exists/iterate), entries immutable once minted,
  collision = loud koru error citing both registrants.
- **Type comprehensions**: one closed comprehension core (binder +
  `over` domain + guard + projection; total, decidable, comptime-
  evaluated — the regex→DFA discipline) with the registry as one domain
  among several: comptime ranges (table.kz, unmarried), registry
  entries, store rows, external schemas (providers — F# type-provider
  territory; Stage C can read disk/net). Firing modes inherit the store
  O13 duality: bake-now vs standing. Liquid is NOT fused — it stays the
  dumb emission assembler comprehension results feed into. Guard word
  (`keep` vs `when`) is an OPEN Lars ruling (O4 leans `when`).
- **Struct blocks are lists of FIELD PRODUCERS**: a literal field row is
  the trivial producer, a comprehension clause (row opening `<binder>
  over`) the generative one, mixed freely — the common declaration
  reads byte-for-byte conventional; power is an optional row form
  (340_007/008/009).
- **Logical/physical split**: the registry entry is the logical type;
  physical layout (packing, endianness, per-arch, SIMD alignment) is a
  variant-selected, guard-constrained projection. Native-layout vs
  wire-layout are different projections of one entry, convertible only
  through derived codecs — endianness misuse becomes a phantom-checked
  type error ("physical projection as checked state", Lars: same
  taint-tracking system doing its job extended).
- **Checked earlier**: binding/continuation/branch payload types today
  are strings — loosely shape-checked, truly rejected only by Zig.
  Registry-backed checking rejects at the Koru layer with koru
  diagnostics naming both types (pins 030_132/133, 340_006 demand
  `error[KORU`, so a Zig-layer rejection can never satisfy them).

The corpus is the spec for all of this: the 035/340 type clusters were
un-parked from category-TODO invisibility 2026-07-07 and now burn
honest-red (17 red / 7 green across 24), each red naming one gap of
this design. Comptime execution discipline (obligations checked BEFORE
evaluate-comptime) is the sibling belief:
frag-comptime-obligation-discipline.

## The ground shifted: types are data, so the registry IS the type system (2026-08-13)

Settled in the type-system design walk, in the shadow of the corpus-purity
sweep: because types are MINTED BY A LIBRARY (`std/types` is a Koru library,
not a grammar), Koru has no built-in type grammar for the language to be
clever about. "Comprehending types" is not a separate feature — it is
comprehension over library data. The registry is therefore not a substrate
under the type system; it *is* the type system, wearing a library's clothes.
Everything a language does with a type — declare it, check it, derive from
it, project it, argue about it — happens at comptime over one dumb table.

Three rulings fall out and are now load-bearing:

- **Registry-first ordering.** The first build is the dumb table itself
  (register/lookup/exists/iterate over a Zig storage core, threads through
  the compiler, primitives as seed entries, collision = loud koru error). It
  is where "this actually starts working." The first green that proves it is
  030_132 rejecting `box#f64` vs `box#i64` — and 030_133 (`Feet`/`Meters`)
  and 340_006 (bounding type) — at the KORU layer, in Koru's own voice,
  before Zig.
- **"What a type IS" is open, and the registry accommodates it.** Declared
  structs, nominal wrappers, stamped identities, phantom carriers,
  behavioral resources, compiler-synthesized event shapes, comptime-only
  reflections — all are entries or participants. Entries are minimal on
  identity, rich on facets (structural/layout/behavioral/provenance),
  generous on participation. The value-level half of nominal distinctness
  already rides the phantom checker (`feet!` vs `meters!`); the registry
  extends the SAME argument from value states to declared-type identity —
  it does not invent distinctness, it gives declared types what phantoms
  already give primitives (pins 030_132/133/340_006 reframed 2026-08-12).
- **Sum types need no generics.** A closed, exhaustive variant set (Rust-style
  enum: `Result { ok: T, err: E }` spelled with concrete signatures) is fully
  expressible with ZERO type parameters. Generics stay parked where the
  2026-06-13 ruling put them — a comptime codegen library, identity in the
  stamped name. So the enum surface can proceed now (rung 1: tagged unions +
  match; rung 2: exhaustiveness by the comprehension's totality), without
  touching the generics question at all.
- **Types are first-class all the way down — data does not demote them.**
  "The registry IS the type system" means the language reads a type, checks
  it, derives from it, and composes it before Zig — which is what *first-class*
  means, taken to its end. `std/types:struct(Player)` is not a workaround or a
  second citizen; it is the first-class surface, and the registry is what makes
  every declared type real the instant it exists. First-class types never
  required a compiler grammar; they required the language to take types
  seriously. This guard exists so the types-as-data framing is never read as
  "we should not build `std/types`" — the library is the type system's surface,
  and the registry is the power behind it.
---

## The ground shifted again: the type column is nearly empty BY DESIGN (2026-08-23)

The synthesis walk (this session, with Lars) dissolved the remaining constructs
and narrowed what an entry can BE. Rulings, each falsifiable:

- **`std/types:struct` is retired, not redesigned.** Corpus verdict: 94 files
  use it inside its own test clusters, ZERO organic consumers across hundreds
  of sessions of real programs (json.kz reached for host+phantoms, boids for
  stores, the compiler for host injection). A feature whose only demand is its
  own test cluster was redundant with the language spine: composition is the
  flow's native operation, so a composite-type construct duplicates it.
  Doctrine going forward: a construct proposal must name the flow operation it
  duplicates before it is taken seriously.
- **Stamped names (`#`) die with the mint.** They were plumbing for standalone
  mints; standalone mints no longer exist. Identity lives in structured entry
  fields (family + ordered param refs), display names derived, emission
  mangles deterministically. The 030_110–123 stamped cluster retires
  un-pinned; its "demand marker" (030_112) proved circular — pressure came
  only from the type tests themselves.
- **Entries narrow to five kinds**: base types (seeded), schemas (born from
  memory declarations — store create/grid reserve/kernel element), state
  carriers (phantoms), projections (physical layouts). SHAPES ARE CHECKED,
  NEVER MINTED — in-flight composites stay anonymous, checked point-to-point;
  they become data only when comptime comprehends over them. Switch dissolves
  into cond (values) + branch arms (variants, exhaustiveness by totality).
- **The instance law** (pins: 600_STDLIB/695_INSTANCE): a constructor is a
  forcing function over the property list — every property instantiated, each
  according to its kind. Reference slots accept ANY tor satisfying the
  `<Type<state!>>` signature (states cannot be forged, so producer chains root
  at real acquisitions); scalar slots accept plain values. Storage duration
  must not exceed permission duration — borrows lend bodies, obligations rent
  indefinitely, so instantiated slots accept only bang-states. There is no
  malloc verb, no constructor keyword, no aggregate value: scalars get bytes
  once, pointers get witnesses, `instance` returns the property list as a bare
  record with obligations pre-attached per field, and downstream handling is
  the ordinary obligation machinery. The heap demotes to "where hosts live" —
  Koru's own memory is static-declared (stores/grids) or ephemeral (values).
- **Parked, adjacent, not designed**: bulk instantiation (1000 instances) is a
  DIFFERENT case from single instantiation — likely one allocation shaped like
  a std/list/array of the proto, closer to grid/store extent semantics than to
  insert; possibly spelled like an `! each`-branch over a for. Reopens nothing
  above; needs its own day.

Falsification conditions, written down BEFORE pressure arrives: one real
program that cannot be expressed honestly without a user-minted layout, a
borrow slot at instantiation, or a named shape alias reopens the corresponding
door. Go spent a decade resisting generics without a written reopening
criterion; we did not repeat that.
---

## The walk closes: instance dissolves; proto returns as pure NAMING (2026-08-23, late)

The same session audited its own instance law and it did not survive — the
fourth dissolution of the day, and the cleanest:

- **`instance` failed its own semantics.** Every consumption of an instance is
  field access inside a flow; the clause is a record literal whose entire body
  is "evaluate these expressions and put their results next to each other."
  Ordinary calling already does that. Composition mints presence, not bytes —
  and presence needs no verb. The construct ate itself. Doctrine confirmed
  four times over (struct, switch, mem:new, instance): proposals keep
  dissolving until only operations remain.
- **What survives is boundary law, not machinery**: storage duration must not
  exceed permission duration (borrows lend bodies, obligations rent
  indefinitely); slots accept any tor satisfying the bang-signature (states
  cannot be forged); partial presence is nonexistence. These attach to ANY
  persistence boundary and need no construct.
- **The heap conclusion stands**: growth is the ONE legitimate allocation
  trigger, and std/list already contains it correctly — allocator inside the
  handle, `<list!>`/`<list>`/`<!list>` states. The heap remains where acquired
  things live.
- **The lawful reopening of the named-shape door**: containers push element
  identity into signatures AND into monomorphized/generated names
  (`List_<element>`, `new-<element>`). Anonymous shapes do not survive that
  trip — re-spelling drifts across sites into silently-different list types,
  inline expressions mangle into unspeakable identifiers (the interpreter.kz
  alias war story, recurring), obligation nesting becomes unspeakable in
  return position. Names exist when a second party must find the thing; with
  containers, the compiler itself is the second party. The held-shut door was
  knocked on by rule, not by taste.
- **The landing — `std/types` as the registry front door**:
  `~std/types:proto(name) { fields }` declares layout-SILENT entries. The
  name `struct` stays dead deliberately: it asserts physical field-stacking,
  which SoA store rows contradict — layout belongs to projections, never to
  identity. Module-qualified resolution through expression paths
  (`std/list:new(app/car:garage)`); the file-domain/module-domain pitfall
  (115_018 family) is known territory. **Name the ELEMENT, derive the
  container** — `*List<garage><list!>` — never hand-name container×shape
  pairs (`EngineList` conflates record with table). Inline-named shapes at
  first use may arrive later as sugar registering into the enclosing module's
  namespace. Sequencing: list consumes protos first; store adopts references
  after (its apply-synthesis gains an entry-resolution step); packed or
  parameterized variants are parked AT the traits border, demand-marker only.
- **Genuine gap ranked next**: the storage-references ruling — receipts inside
  storage have no binder for the checker to police. Store's answer
  (generation handles, resources outside, validity checked never owned) is
  the precedent. This knocked three times today; it is the first design day
  when composites enter collections.
- **Pin disposition**: the 696_INSTANCE pins tested the dissolved verb and were
  retired 2026-08-23 (all six deleted; per-pin reasons in the retirement
  commit). The three boundary laws live HERE and replant against the first real
  acquisition boundary — likely list-of-proto persistence.
- **Cutover executed (2026-08-23, same day)**: all four mint verbs (`struct`,
  `type`, `enum`, `union`) are removed from koru_std/types.kz; 24 consumer
  tests retired across the 030/340/115 clusters — sixteen green museum pieces
  plus eight honest-reds — with zero green→red flips among survivors (four
  failures in the verification run all pre-date the cut). Doctrines that rode
  dead vehicles and now replant on proto entries: registry-backed nominal
  distinctness (was 030_132/133, 340_006), field reflection over real schemas
  (`fields-of` survives; was exercised via 340_012/013 mints). std/types holds
  only fields-of + nominal primitives and deliberately declares NO composite
  type until proto lands with list as its first consumer. Known residue: the
  stamped-name quoting in emitter_helpers.zig is unreachable until proto's
  derived names need it again.

Falsification conditions carry forward unchanged, plus one: a program that
cannot agree on a composite across sites without a named entry confirms proto;
a program satisfied by inline shapes everywhere dissolves it again.

---

## The law sharpened: affinity, not coupling; sameness by NAME only (2026-09-03 walk)

A walk co-derived (with Lars) what proto is past the negative — and the
landing made it real. The row rule, the thing every earlier rung circled:

- **A proto names an AFFINITY, never a coupling.** `struct` fused identity
  with physical arrangement at declaration; proto keeps the name AND nothing
  else. There is never an `Engine` value; a consumed proto self-erases to the
  `// proto Name: fields` marker. Consumers (std/list, std/store, std/kernel)
  derive their own physics from the same entry — SoA store row, AoS list
  element, same contract, different arrangement.
- **"Same thing" is by NAME ONLY — the disambiguation.** `health: Health` in
  Player and Enemy is the SAME concept (same column, dedup default); raw
  `health: f32`, or `health: Vitality` even terminating in f32, is a
  SEPARATE concept, refused loudly when combined. The layout system may merge
  only what a shared name proves identical — never two anonymous fields that
  merely look alike. That is "no unearned claim" applied to memory itself.
- **The ECS contrast that framed it**: a component is a named field set with
  a relation to an entity — composition is membership, never embedding. Proto
  is that, one step more abstract: no entity, no payload, only the tendency.
  "Components" felt too struct-y because ECS components are still values
  attached to entities; proto has no body by construction.
- **A type is a path that terminates in something not compound.** Every proto
  resolves to scalars by construction; the compound field surface (scalars
  only this rung) is the terminal rule's day-one shadow. The tree already
  carried it as a field-level wall.
- **Inheritance done right = compose the same CONCEPTS in DATA, never in
  behavior.** Behavior is what consumers derive (never inherit); identity is
  what composes. Data-composition is the sound half of inheritance,
  unbundled.
- **Doubling is waste, not truth.** The layout algebra's cost rule: never
  charge the same scalar twice when one name could have served. The proto
  system is a guiding system against the double — the "same f32, not two
  f32-fields" payoff when two stores share a proto.
- **The module splits**: `std/proto` is the compound front door; the nominal
  primitives (`std/types:string(Email)`) are the SAME act at field count
  zero — a name, not a wrapper tax. The old frame (distinct named wrappers)
  upgrades to identity-at-comptime.

## The default door landed (2026-09-03): std/proto(Engine) { … }

- `std/proto(Name) { fields }` invokes the module's `default` tor through the
  default-event rule (`std/M(args)` ≡ `std/M:default(args)`, import_pipeline
  rewriteDefaultEventCalls — a proven pattern, constructor.kz). The module
  name IS the verb; `default` is reachable only through the path.
- **`koru_std/proto.kz`** (new): the `default` transform tor — the proto
  body verbatim from std/types, one message prefix changed. Self-erases to
  the IDENTICAL `// proto Name: fields` marker.
- **Three-site widening** so the new door registers like the old:
  `phantom_semantic_checker.zig` + `type_registry.zig` scanDeclaredTypes /
  populateFromItem (accept `std.proto`/`std/proto` mq, `default` verb as
  proto when on the proto door), and `list.kz` findProtoDecl. After the
  rewrite mq is the canonical dotted `std.proto` (import local_name rule),
  so the widening is the same two-form match the old door already uses.
- **Pins**: 660_030 (run slice through the new door) and 660_031 (duplicate
  refusal through the new door). The harness gate lesson: a negative test
  needs a `MUST_ERROR` FILE, not just the `MUST_ERROR` line in EXPECT.
- **Fixed-point insight**: the consumer path (programHasProto + field source)
  falls back to the ERASED MARKER, which both doors write identically — so
  the new door composes with std/list for free, and the registration scans
  were the only real seam.
- **Three pre-existing 660 reds untouched** (002, 013, 026) — board reds
  predating this session.

Ruled and landed the same day (terminal half): `std/proto:string|int|float|bool(Name)`
are the named-primitive home — same host lowerings as the legacy wrappers
(`float` → `f64`, kept deliberately), each writing a `// proto-terminal Name:
kind` identity marker ahead of its alias so compounds resolve references
regardless of transform visitation order. The default tor accepts a scalar
material or a declared terminal and refuses unregistered words loudly
(KORU173, `names unknown terminal`). Terminal names collide loudly
(`DeclaredTypeSite.is_terminal`, no `List_` container derived) while legacy
`std/types` wrappers stay idempotent — the same act at field count zero,
finally under the proto roof. Keyword deliberately absent on the new verbs:
terminal identity is module-spaced, never a bare global.
**Pins**: 665_001–665_009 (`665_PROTO`).

Stated, not solved (module-awareness asymmetry): imports merge and every
layer walks the merge, but registration keys bare names globally — two
modules minting `Health` collide rather than coexist, and the checker
confesses the mirror blind spot (cross-module same-name types compare
equal; the type→declaring-module map does not exist yet). "Identity is
`{path, name}`" is the intent; "identity is `{name}`, one registry" is the
machine. The qualification half exists at consumption (`app/car:Engine`
filters by declaring module); the namespace half is unbuilt.

Open and next (un-ruled): what an identity actually is — the
type→declaring-module map, i.e. whether two homes may mint one name;
the layout algebra itself (shared columns by terminal).
Falsification conditions carry forward; the "merge only by name" law adds
one: two anonymous same-shaped fields silently sharing a column would
dissolve it.

## The module rung landed (2026-09-04): identity is (home, name)

The asymmetry above is solved at registration and reference, not at layout.
Rulings, each falsifiable:

- **Registration keys the home.** The checker's sites map went composite, so
  the two-registrant wall fires same-home only and two homes minting one bare
  name coexist as distinct concepts. The nominal gate still answers the bare
  question (is this name minted anywhere) and is unchanged.
- **References canonicalize; they never search.** A bare field answers to its
  own scope, a qualified field to the named home — the corpus-wide rule for
  every other reference, extended to terminals. Imports grant spellability,
  never candidacy: an unimported declarer cannot break or confuse your scope.
  The "ambiguous bare ref" therefore does not exist as a case; the strict
  alternative was considered and refused as spooky action at a distance, and
  the home-first alternative as comfortable duplication.
- **The default door rewrites per scope.** Imported modules' bare module calls
  resolve against their own imports after the merge; the entry-only pass was a
  gap, not a boundary.
- **Pins**: 665_010 (coexistence), 665_011 (door in imports), 665_012
  (qualified ref), 665_013 (unknown qualified refused), 665_014 (bare ref is
  home-scoped: unknown, never guessed); 008 respelled qualified.

Open and next, unchanged in shape: qualified consumption in deriving consumers
(bare element lookup still takes the first program-wide match), the layout
algebra itself, kind synthesized on usage. The store half of the payoff is
pinned red (690_272, entry-resolution missing) with its query shape pinned
green beside it (690_273, hand-tagged). Falsification conditions carry
forward; the merge-only-by-name law is now enforced at three sites and would
dissolve the same way at any of them.

## The foreign door (2026-09-04): `std/foreign`, the airlock

Host-owned identities register without deriving. `std/foreign:struct(File)`
mints a name plus bare field names — presence claims, never types: Koru
checks what it owns (does `File` have `path`), the host checks what it owns
(spellings, layout). Same registry, same `(home, name)` collisions, no
container, no proto-field embedding in either direction. Deliberately ugly
by spelling; inspection-only forever, any further verb reopens the ruling.
Double book-keeping is inherent to airlocks and is answered by claim-and-
prove (build-time reflection probes), never by a Koru-side host grammar —
parsing the host language stays refused no matter how much hand-mirroring
hurts, until a real program in pain says otherwise. Pins 667_001–006 green;
the prove half and value-level interop are the rungs beyond.

## The deref check landed (2026-09-04): presence claimed, presence checked

Rung 2 keeps the airlock's promise at the Koru layer: a bare-return produce
of `binding.field` against a foreign-typed binding is refused (KORU030,
naming field and entry) unless the field is a registered presence claim —
pin 667_004 green. Present fields wave through untouched; what `*File`
lowers to is host linkage's question, not this check's. Two placement
rulings, each falsifiable:

- **The check reads the erased marker, not the declaration.** The shape
checker runs post-transform, past the struct tor's self-erase — so the
field list comes from the `// foreign Name: fields` comment, with the live
flow as the pre-erase twin. Same fixed point the list consumer already
rides; a checker that only reads declarations goes blind exactly when the
pipeline has done its work.
- **The deref shape is the produce shape.** `f.bogus` arrives as a
  bare-return `plain_value`, not a field-access node — the identity-branch
  form, one bare value. The check therefore lives on the immediate-impl
  produce path, keyed off the event's input binding type, and general
  expression-position projection checking stays unbuilt until a pin demands
  it.

Open and next: entries travel across imports (667_006 green — the entry
lives in the imported lib, the deref in the consumer), which is what lets a
future std module own its host concepts the way std/io would own `File`.
Resolution today is bare program-wide; the home-scoped module rung from the
proto precedent (665_010–014: bare refs home-scoped, imports granting
spellability) is unbuilt for foreign. It reopens the day two libraries mint
one bare name and a deref must pick its home.

## The linkage landed (2026-09-04): references canonicalize to the host home

Rung 3 answers "where its declaration comes from": a bare foreign-claimed
type that some module's host code declares routes to that home at emission
(`*File` → `*koru_app.koru_lib.File`) — references canonicalize, never
search, the module-rung rule. The host name IS the type: nothing is
generated, so no substance is invented. Pin 667_005 green — claim and host
companion together in lib.kz (the shape a future std module owns its host
concepts in), the consumer derefing through the import, the program running.
Rulings, each falsifiable:

- **The gate is double: claimed AND declared.** Either condition missing
  falls through to verbatim — unknown stays unknown, the backend owns it.
  The rung stays supplemental: it can only turn a backend
  undeclared-identifier into an earlier routed reference, never refuse a
  working program. A top-level ("") home resolves bare and falls through
  too.
- **The probe was cut, not landed.** A claim-and-prove comptime probe beside
  the marker is the law's letter, but Zig analyzes lazily: the probe runs
  only when something links the host type, and nothing can link one until
  real Files flow — so it could neither pass nor fail a pin, and an
  unrunnable guard that can refuse builds is a loaded gun. It returns with
  value-level interop, carrying firing pins. (One loaded round found on the
  way out: a bare reference resolves lexically past `@hasDecl` — the future
  probe must bind through `@field`.)

Open and next: coexisting same-name hosts (first-declaration-wins today, per
the home map); the prove half; value-level interop — calling with a real
File, the further rung 667_005 always named.

Demand criterion (set 2026-09-04, the taste review): no rung 4 — no
prove-half, no value interop, no new foreign surface — until a real host
concept wants it: an stdlib module adopting an entry, or a program in pain.
A feature whose only demand is its own test cluster gets retired, not
extended; that ruling already took `std/types:struct`. The post-transform
two-form scan was consolidated to one canonical collector
(`type_registry.collectForeignEntries`, both consumers calling it) ahead of
the wait, so the corner stays small while it waits. Falsified the day a
real entry lands outside the 667 pins.

## The nesting landed (2026-09-04): compounds compose by expansion

The bad look is gone: a compound field may name another compound, so
`pos: Position` declares instead of refusing. Nesting means transparent
expansion — a graph-walk instantiating scalars, never dereferencing: the
compound dissolves, only leaves materialize, and there is no `pos` value
anywhere. Two node kinds, two merge rules: terminals merge globally by name
(a `Health` leaf is one column wherever reached), compounds expand locally
by path (two `Position` fields stamp two `x`es, never one aliased cell).
Raw leaves merge iff their full chain matches — the shared compound name in
the chain is what distinguishes foldable `pos.x ≡ pos.x` from never-foldable
bare `health ≡ health`. Records stay atomic within one extent by
construction; folding is across extents, and same chain with different
substance refuses loud. Pins 668_001–004.
Rulings, each falsifiable:

- **The gate opens, the unknown still refuses.** Compounds join scalars and
  terminals as legal field types under the same home rules; genuinely unknown
  words keep the exact existing refusal (665_005/014 untouched). The DAG law
  lives with the declaration: cycles refused with the chain named, walked
  only when some field is compound-typed, flat entries paying nothing.
- **Expansion sits at the single choke point.** `protoFieldsOfProgram`
  flattens to dotted-leaf pairs; list — the only field consumer — flows
  first-leafs exactly as before, so synthesis is untouched and a nested
  first field feeds it the first leaf. A name already expanding passes
  through unexpanded: unreachable while the gate refuses cycles, kept so a
  walk over unvalidated declarations can never hang.
- **Out, explicitly:** value-level records (no construction surface),
  raw-separation pins (beyond the first leaf nothing flows). Store pack
  and set-fold are not this walk's — they are 690_285–287.

## A lone store packs; a set folds (2026-09-05)

Sibling seed fields as kinds (`player: Player, enemy: Enemy`, fold by
bare name, hidden `kind`, one insert plus zero-fill) was never the
store surface. A `Source` block is opaque text; that spelling was a
consumer habit, not a language constraint. 690_274–284 are marked
BROKEN so they cannot sit as stdlib truth.

What holds:

- **A lone store packs.** Each proto in the seed is its own placement.
  The DAG dissolves to path-named leaves (`left.health`, `right.health`).
  Same concept at two paths is two cells. Two protos are two concepts.
  No fold. Query of a path is one packed leaf, not a pointer walk.
  Pins 690_285, 690_286.
- **Fold is a store-set act.** `std/store:set` lists logical stores;
  that list is the kind vocabulary (`e is Player`). Join key is
  (path-from-that-store's-root, type). Insert and obligations stay on
  the logical store. A store in no set keeps its own layout. Pin 690_287.
- **690_272 is Slice A**, not a union: a handwritten `health: Health`
  column. Terminal identity in field position. It stays.

What would `correct` this: a lone store that merges two placements of
the same leaf name into one column, or a set that does not fold
`str: Strength` across its members.

### The set is the authority, not a second seed (2026-09-05b)

Landing the section above (690_287 extended with an unguarded fold
query) forced a precedence ruling the design left implicit. A store
named by a set resolves its kind members from the set — set outranks
the `new`-seed twin everywhere kinds are read: members, schemas,
write-demand, home. The seed stays as fallback for lone stores, which
keep packing (690_285). The prior mechanism had only one source and so
never had to choose; two sources made precedence the belief, and
"set wins" is the ruling.

Second fact the section understated: over a set, a query with NO kind
guard is legal and folds every member — polymorphism by omitting the
guard. This does not repeal the unnarrowed-read refusal (690_282);
guards narrow kinds on a kinded store, and no guard over a set means
all kinds. What would `correct` this: an unguarded set query that
silently skips a member kind, or a set-and-seed store whose members
come from the seed.
