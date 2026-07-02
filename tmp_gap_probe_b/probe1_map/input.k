// PROBE 1: string-keyed map store — 3 string->i64 pairs, read one back, print.
// Grounded on tests/regression/600_STDLIB/660_COLLECTIONS/660_024_string_map_trunk/input.k
import std/io
import std/string-map

std/string-map:new()
| map m |> std/string-map:set(m, k: "d", v: 72) |> std/string-map:set(m, k: "e", v: 507) |> std/string-map:set(m, k: "f", v: 492) |> std/string-map:get(m, k: "e")
    | value v |> std/io:print.ln("e={{ v:d }}") |> std/string-map:free(m)
    | missing |> std/io:print.ln("MISSING") |> std/string-map:free(m)
| err e |> std/io:print.ln("ERR {{ e:s }}")
