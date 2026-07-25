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
// item of the entry file.
//
// Mechanism, proven by probe rather than inferred: this is NOT a store bug. The
// parser's implicit-`expr` remap (parser.zig, the `has_implicit_expr` block)
// needs the event registry to know the target's input shape, and an imported
// module is parsed BEFORE the stdlib's declarations are registered — the same
// invocation reports registry_hit=false on that first parse and true on a later
// one. So a module's args arrive still punned to their own value
// (`name=cache value=cache` instead of `name=expr`), `new` fails its very first
// argument check, and it raises an error that then VANISHES: errItem emits
// `comptime { @compileError(...) }` as inline_code into that module, and it
// never reaches the emitted Zig. Two defects, and the second hides the first.
//
// Any transform taking `expr: Expression` is exposed to the same ordering —
// 62 of the 85 transform declarations in the corpus.
//
// The two pins fail independently: 110_022 stays green while a module cannot
// own a store, and this stays green if reach regresses.
import std/io
import app/lib

app/lib:bump() |> app/lib:peek(): a |> std/io:print.ln("v={{ a:d }}")
