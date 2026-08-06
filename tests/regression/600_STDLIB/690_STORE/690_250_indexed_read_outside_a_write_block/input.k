// A HANDLE-ADDRESSED store read lowers OUTSIDE a write block — in a `{{ }}`
// interpolation and in an `if` guard, which are the two positions this file
// was written red to name.
//
// `head.h` — a singleton cell path — always lowered anywhere in the program,
// because `std/store:new` owns a whole-program rewrite for it. `cells[head.h].v`
// did not: the indexed form was lowered only by `stored`'s own value pass, so a
// guard or an interpolation reached the host as `cells[...]` and the Zig
// backend reported an undeclared identifier naming no Koru construct.
//
// IT WAS NEVER A MISSING FEATURE, and the shape of the absence is the thing
// worth remembering. `indexedFieldRefs` was complete — it recursed through
// nested indices (690_245), it had its own pin — and it lived inside the helper
// struct scoped to the `stored` transform. The whole-program walk that `new`
// runs carried a DIFFERENT helper struct, holding only the singleton rewriter.
// A private helper struct inside a transform is a LOWERING BOUNDARY, however
// much it reads as ordinary code organisation, and store.kz had five separate
// `storeRefs` copies in five scopes to prove it.
//
// WHAT CLOSED IT: the rewriter moved to file scope (`storeIndexedRefs`), the
// `stored` copy now delegates there, and both whole-program walks — singleton
// and plural — call ONE `storeLowerText` per text slot: cell paths, then
// indexed reads, in the order `stored` always used.
//
// A HALF-RULE CAME OUT WITH IT. Two of the five `storeRefs` copies excluded a
// following `[` from the one-column identity case, with a comment saying "so a
// row index still takes the indexed path below" — and those were exactly the
// two copies that HAD an indexed path below them. The other three did not
// exclude it, because in their scope there was no indexed path for the base to
// be stolen from. Half a rule each, correct only beside the other, and moving
// the indexed lowering into the walks is what made the missing half load-bearing.
//
// The sibling gap in a CALL ARGUMENT is 690_254; both closed together, and
// 690_253 is the write-side twin that composed years earlier.
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
