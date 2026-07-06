# The type system — registry, stamped names, comprehensions (design belief)

Koru's type system is grown, not decreed: a **dumb, metadata-loaded
registry** in the gray zone (a koru_std module the compiler relies on —
list.kz style: Koru surface events over a Zig storage core, threaded
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
