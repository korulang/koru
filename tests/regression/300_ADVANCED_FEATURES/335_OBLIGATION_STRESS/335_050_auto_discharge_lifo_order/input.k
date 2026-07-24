// Obligation stress — auto-discharge unwind order must be LIFO.
//
// Intent: when auto-discharge inserts MULTIPLE releases at scope exit, they
// must unwind LIFO — last-acquired released FIRST. `child` is acquired while
// `parent` is still held, so `child` depends on `parent` being live; releasing
// `parent` first is a use-after / invalid-state hazard. Reverse-acquisition
// order is the RAII / defer / drop guarantee, and the only safe order for
// nested dependent resources. The correct trace releases `child`, then `parent`.
import std/io

pub tor acquire { name: string } -> string<held!>
acquire -> name

pub tor release { name: string<!held> }
release = std/io:print.ln("release {{ name:s }}")

acquire(name: "parent"): parent |> acquire(name: "child"): child |> std/io:print.ln("both held")
