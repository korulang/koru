// ASPIRATIONAL (see TODO): a HANDLE-ADDRESSED store read outside a write block.
//
// `head.h` — a singleton cell path — lowers anywhere in the program, because
// `std/store:new` owns a whole-program rewrite for it. `cells[head.h].v` does
// not: the indexed form is lowered only by `stored`'s own value pass, so a
// guard or an interpolation reaches the host as `cells[...]` and the Zig
// backend reports an undeclared identifier naming no Koru construct.
//
// This is the exact gap std/grid closed for cells on 2026-08-03 (697_005), and
// finding it there is what made it checkable here. The two are one shape: a
// declaration that owns the read surface for its own addressing form, in every
// position an expression may stand.
//
// It is NOT a missing feature. `indexedFieldRefs` already exists and already
// recurses through nested indices (690_245); it lives in a helper struct scoped
// to the `stored` transform, and the whole-program walk that `new` runs carries
// a different helper struct with only the singleton rewriter in it. store.kz
// has four separate copies of `storeRefs` in four scopes, which is how a
// rewriter can be complete in one of them and absent from another.
//
// Flip this to passing by giving the declaration's walk the indexed lowering —
// shared, not a fifth copy.
import std/io
import std/store

std/store:new(cells, capacity: 4) { v: i64 }
std/store:new(head) { h: -1[i64] }

std/store:insert(cells) { v: 7 }
| row a |> std/store:stored { head.h: a }
| full |> _

std/io:print.ln("interp {{ cells[head.h].v:d }}")

if(cells[head.h].v == 7)
| then |> std/io:print.ln("indexed guard ok")
| else |> std/io:print.ln("indexed guard WRONG")
