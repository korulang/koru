// 690_053 — OWNED-STRING column (B-narrow): a store column holds an owned
// *std/string:String<std/string:instance!>, threading the obligation through
// the store boundary. insert CONSUMES the caller's <std/string:!instance>
// (ownership moves INTO the store — push by move); take REISSUES
// <std/string:instance!> on the row payload (ownership moves back OUT — pop
// by move); store teardown auto-frees each still-live element via the
// canonical discharger std/string:free, resolved across the module boundary
// exactly as 690_036 resolves the entity discharger. Round-trip: "hello"
// moves in owned, comes back out owned, is read, and auto-discharge frees it
// at scope exit (610_014's rule — no manual free). "kept" stays IN the store,
// pinning the teardown-frees-live-elements path.
import std/io
import std/string
import std/store

std/store:new(names, capacity: 8) { name: *std/string:String<std/string:instance!> }

std/string:from-page(text: "hello")
| ok s |> std/string:take(s): owned |> std/store:insert(names) { name: owned }
    | row r |> std/store:take(names[r])
        | item i |> std/string:read(s: i): text |> std/io:print.ln("{{ text:s }}")
| err _ |> _

std/string:from-page(text: "kept")
| ok s2 |> std/string:take(s: s2): owned2 |> std/store:insert(names) { name: owned2 }
    | row _ |> _
| err _ |> _
