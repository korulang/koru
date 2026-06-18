// PINNED GAP (currently RED) — the IDEAL unified generic-map surface we want
// after the naive phase: ONE `std/map` whose key/value types are chosen at
// construction, with ops that dispatch on the handle's concrete type. Today this
// fails: `new(string, i64)` is not a [transform], and a string-typed `set`/`get`
// in the `map` module collides with the i64 ones ("duplicate struct member
// name") because events lower to a `<name>_event` member keyed by NAME ONLY —
// there is no overload-by-handle-type and no type registry for the call site to
// resolve against. This is THE dispatch gap the naive per-type modules
// (std/string-map) route around honestly; greening this test is the post-AoC
// generics milestone (ties to the type-registry work).
import std/io
import std/map

std/map:new(string, i64)
| map m |> std/map:set(m, k: "a", v: 1) |> std/map:get(m, k: "a")
    | value v |> std/io:print.ln("{{ v:d }}") |> std/map:free(m)
    | missing |> std/io:print.ln("MISSING") |> std/map:free(m)
| err e |> std/io:print.ln("ERR {{ e:s }}")
