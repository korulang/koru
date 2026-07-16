// Obligation stress — auto-discharge unwind order must be LIFO.
//
// Intent: when auto-discharge inserts MULTIPLE releases at scope exit, they
// must unwind LIFO — last-acquired released FIRST. `child` is acquired while
// `parent` is still held, so `child` depends on `parent` being live; releasing
// `parent` first is a use-after / invalid-state hazard. Reverse-acquisition
// order is the RAII / defer / drop guarantee, and the only safe order for
// nested dependent resources. The correct trace releases `child`, then `parent`.
//
// RESIDUAL: today auto-discharge emits releases in the obligation map's
// (StringHashMap, keyed by binding-variable name) iteration order, which is not
// acquisition order — so this releases `parent` before `child` and is RED until
// the inserter unwinds in reverse-acquisition order.
import std/io

pub event acquire { name: []const u8 } -> []const u8<held!>
acquire -> name

pub event release { name: []const u8<!held> }
release = std/io:print.ln("release {{ name:s }}")

acquire(name: "parent"): parent |> acquire(name: "child"): child |> std/io:print.ln("both held")
