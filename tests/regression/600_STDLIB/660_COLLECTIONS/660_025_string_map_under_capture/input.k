// std/string-map nested under a capture's <map!> obligation — proves the
// string-keyed map (duped-and-owned keys) rides the capture sequential-sibling
// auto-discharge fix (329a55f2): set one key => count 1; the <map!> discharged
// exactly once, all duped keys freed, no double-free / leak.
import std/io
import std/string-map

std/string-map:new()
| map m |> capture { n: 0[i64] }
    ! as acc |> captured { n: acc.n + 1 } |> std/string-map:set(m, k: "x", v: 7)
    | captured _ |> std/string-map:count(m)
        | count c |> std/io:print.ln("{{ c:d }}")
| err e |> std/io:print.ln("ERR {{ e:s }}")
