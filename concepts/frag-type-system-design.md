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

Open and next (un-ruled): the terminal half — `std/proto:float(Health)` as
the named-primitive home (the "same column, different rows" payoff); the
layout algebra itself; transitivity module-qualification of proto fields.
Falsification conditions carry forward; the "merge only by name" law adds
one: two anonymous same-shaped fields silently sharing a column would
dissolve it.
