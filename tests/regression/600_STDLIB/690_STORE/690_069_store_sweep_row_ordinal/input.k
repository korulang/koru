// PINS (RED, awaiting implementation): a query arm's destructure block is a
// REQUEST, and its entries carry PREFIX ANNOTATIONS naming what the visit
// should synthesize. Here: the row itself, and the 0-based layout cursor a
// retained renderer needs.
//
// RULED 2026-08-03 by Lars, after this pin sat unspellable for a week:
//
//   1. The block is a REQUEST — the transform synthesizes what is asked for,
//      and ONLY what is asked for. An unrequested ordinal materializes no
//      cursor, the same way an unread aggregate materializes no column.
//   2. Entries are annotated with the language's normal PREFIX form —
//      `[comptime]tor`, `[keyword]`, `[global(name)]`. `r[mutable]` is postfix
//      only because it hangs off a binding; prefix is the convention.
//   3. LOCAL TO query/store. This is deliberately NOT a language-wide loop
//      counter: `for` has the same missing-index hole and does NOT get this.
//      The store's query is special because it already drives codegen.
//   4. Honored or REFUSED — never silently ignored. Same law as declared
//      reductions ("must refuse to compile, never fall back to serial"). An
//      annotation that cannot be satisfied at a site is a diagnostic naming
//      the site and the reason, not a decoration.
//
// WHY THE BLOCK IS LEGAL AGAIN, when `690_089` refuses a projection block.
// Three separate things were collapsed under one word, "retired":
//
//   - `entity.v` — an UNSCOPED MAGIC TOKEN. Killed because the rewrite matched
//     the literal word across a subtree with no scope, so nested sweeps read
//     the inner store and wrote the outer one in one arm (690_087). Bindings
//     are distinct tokens per nesting level, so this never applied to them.
//   - A COLUMN LIST (`{ v, w }`). Killed because "the projection block said the
//     same thing twice and let the two halves disagree" (store.kz, at the
//     refusal): which columns a site touches is DERIVED from `<row>.<field>`
//     references, never listed.
//   - The BRACES THEMSELVES. Never had an argument against them. The wall is
//     written `if (sc.destructure.len > 0)` — a syntactic ban on brackets
//     standing in for an argument about column lists.
//
// This form is untouched by all three: nothing here is a column, so nothing is
// stated twice and the columns stay derived from `e.v` below. Every entry is a
// binding, so nesting stays unambiguous.
//
// NO PARSE AMBIGUITY. A destructure field accepts an identifier, a dotted path,
// or `_` (parser.zig, the PARSE001 site) — there is no bracket production, so a
// LEADING `[` is unclaimed. It cannot collide with `stored { tree[a].parent }`
// handle addressing, where `[` FOLLOWS an identifier and is parsed by the
// store's lvalue grammar. Position tells them apart.
//
// `! query e` stays legal as the shorthand for `! query { [row]e }` — ~149
// green sites depend on it and rule 1 of 690_086 still governs the row.
//
// STILL OPEN, deliberately not pinned here: whether the block may ALSO name
// columns. If it may, the two killed arguments above come back with them, so
// this pin keeps columns on `e.v` and lets the block carry only what the VISIT
// knows and the row does not. The vocabulary beyond `[row]`/`[ordinal]`
// (`[id]` for the handle, density and write-intent markers that would let the
// dense-cursor codegen be DECLARED rather than inferred) wants one gating
// principle before it grows — the way fusibility has one.
import std/io
import std/store
std/store:new(items, capacity: 8) { v: i64 }
std/store:insert(items) { v: 10 }
std/store:insert(items) { v: 20 }
std/store:insert(items) { v: 30 }
std/store:query(items)
! query { [row]e, [ordinal]n } |> std/io:print.ln("row {{ n:d }} = {{ e.v:d }}")
