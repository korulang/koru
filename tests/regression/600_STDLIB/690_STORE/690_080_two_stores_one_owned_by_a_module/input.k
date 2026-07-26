// PINS: a store owned by an imported module keeps its qualified cell reference
// when a SECOND store is declared elsewhere in the program.
//
// 690_079 pins the single-store version of this: a module may own a store. This
// varies exactly one thing — the entry file declares a store of its own — and
// the variation is not about reach. Neither store is named outside its own
// module; `tally` is untouched by `lib`, `cache` is untouched by the entry.
//
// The axis is REPEATED REWRITING. `std/store`'s create transform runs once per
// `new` site, and each run rewrites cell paths across the WHOLE program — so a
// second store in the program means the first store's references are walked a
// second time, by a pass that is not the one that placed them.
//
// What makes that walk interesting is where the second pass gets its names.
// Collection has two sources: live `new` invocations, and the
// `__store_apply_<name>` tors left behind by an already-transformed store,
// whose `new` site has by then dissolved into a comment. Both stores here do
// synthesize such a tor, so the second route is populated in this program.
//
// What the pin holds is the OUTCOME, not the route: `cache` stays fully
// qualified where the entry file reads it through an inlined `peek`, and
// `tally` stays bare in the module that declared it. Bare is the wrong answer
// for a module-owned store even in its own module — the qualified form is the
// only one that survives the emitter inlining a body into a caller elsewhere.
//
// OPEN: whether the second pass re-derives a prefix for the first store at all,
// or leaves the already-rewritten path alone. Not established here; the
// file-derived home lookup returns null once a `new` has dissolved, and what it
// synthesizes in that case is unexercised by anything in the corpus.
import std/io
import std/store
import app/lib

std/store:new(tally) { n: 5[i64] }

pub tor total {} -> i64
total -> tally.n

app/lib:bump() |> app/lib:peek(): a |> std/io:print.ln("cache={{ a:d }}")
total(): t |> std/io:print.ln("tally={{ t:d }}")
