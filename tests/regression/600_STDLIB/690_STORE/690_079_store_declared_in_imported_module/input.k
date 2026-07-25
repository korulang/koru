// A module OWNS a store: `std/store:new` declared inside an imported module,
// written and read only from that same module. Nothing here crosses a boundary
// — the entry file never names the store, never touches a cell, and only calls
// two exported tors.
//
// This is the library case. A library that keeps private state declares the
// store beside the tors that use it; a store a library cannot declare is a
// library that has to hand its state to its caller.
//
// What this pins is DECLARATION SITE, not reach. 110_022 pins reach — a module
// reaching a store the ENTRY declared — and holds the other axis: the store
// exists, and the question is whether another module can name it. Here the
// question is whether the store exists at all when `new` is not a top-level
// item of the entry file. The store transform's metadata lookups descend into
// `module_decl` in some scans and not others (`storeHomeModule`'s new-detection
// walks top-level `.flow` items only), so the declaring module decides whether
// any cell, apply tor, or write tor is synthesized.
//
// The two pins fail independently: 110_022 stays green while a module cannot
// own a store, and this stays green if reach regresses.
import std/io
import app/lib

app/lib:bump() |> app/lib:peek(): a |> std/io:print.ln("v={{ a:d }}")
