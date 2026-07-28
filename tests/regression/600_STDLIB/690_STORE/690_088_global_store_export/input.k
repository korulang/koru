// PINS: a store is linkable from ANYWHERE in the program by name, across module
// boundaries, with no annotation and no qualified path. RULED — this is the
// substrate property, not an accident of the lowering.
//
//   DESIGN.md:19-21 — "stores are declared (comptime name + shape) and
//   instantiated (runtime moment), LINKABLE FROM ANYWHERE IN THE PROGRAM BY
//   NAME. Reads and writes are events; reactivity is compiled, not subscribed."
//
//   DESIGN.md T1 — a transplanted body's free names must be a subset of
//   {its query-block bindings} u {comptime-known names: module decls,
//   qualified calls, OTHER STORES}. Other stores are a named member of the
//   legal set, so reaching one by name is the design working.
//
// The reason is stated with the rule and is worth keeping in view: koru flows
// have explicit enumerable bindings, which is what makes transplant-purity
// decidable at all. Module-scoping store names would shrink that enumerable set
// and buy nothing.
//
// Written because this test was first authored to pin `[global(name)]` as the
// mechanism granting cross-module access — and it passed with the annotation
// REMOVED, which read as an accident and is not one. Gardened from prose into a
// pin so the next reader meets the ruling as a running test.
//
// A duplication-checked registration (`[global(<name>)]`) is a separate,
// UNRULED question: it would add a wall to a namespace that is deliberately
// flat, not add access that already exists.
import std/io
import std/store
import app/lib/arena

app/lib/arena:seed()

std/io:print.ln("hp {{ game.hp:d }}")
