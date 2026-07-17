// Pins that a binding-position destructure of REAL payload fields compiles —
// both the bare-name form `{ a }` and the representation-annotated form
// `{ a: i32 }` (a legal destructure field shape per the grammar). Guards the
// field-existence wall from over-rejecting valid destructures.
import std/io

event read { path: []const u8 }
| ok { a: i32, b: u8 }
| err []const u8

read => ok { a: 7, b: 2 }

read(path: "x")
| ok { a } |> std/io:print.ln("{{ a:d }}")
| err _ |> _
