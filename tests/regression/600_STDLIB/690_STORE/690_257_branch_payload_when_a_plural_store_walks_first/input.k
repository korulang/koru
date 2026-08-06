// 690_256's twin, and the ONLY program that discriminates between store.kz's
// two copies of the whole-program cell-path walk.
//
// The walk that rewrites `<store>.<field>` into `__koru_store_<store>.<field>`
// exists twice: once on `std/store:new`'s singleton road and once on its plural
// road, in separate scopes, each enumerating the expression positions it visits
// by hand. Both enumerate over EVERY store name visible in the program, not
// just their own — so whichever `new` transform runs FIRST does the rewriting
// and the later one is a no-op.
//
// 690_256 declares only a singleton, so its singleton copy always wins and the
// plural copy is never asked. Declaring a plural store ABOVE the singleton
// flips the order: the plural walk reaches the branch payload first, and the
// singleton walk that fixes 690_256 arrives to find nothing left to do. That is
// the whole difference between the two files, and it is why the plural line is
// here rather than folded into its neighbour.
//
// MEASURED, not assumed — each arm was made inert in turn:
//   singleton arm off, this program  -> still compiles (plural arm carried it)
//   plural arm only,   690_256       -> still `use of undeclared identifier 's'`
//
// A rule spelled twice in two scopes is the standing hazard here: 690_250's
// note already records `indexedFieldRefs` being complete in one copy and absent
// from another, which is the same disease one position over. Two tests is the
// cheapest way to notice when only one copy gets widened next time.
import std/io
import std/store

std/store:new(p, capacity: 2) { v: i64 }
std/store:new(s, capacity: 1) { n: 7[i64] }

pub tor pick {}
| got i64
| none

pick = if(s.n > 0)
| then => got s.n
| else => none

pick()
| got v |> std/io:print.ln("{{ v:d }}")
| none |> std/io:print.ln("none")
