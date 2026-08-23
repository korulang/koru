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
