// std/set trunk: new → add (incl. a duplicate) → count distinct → free.
// Pins the hash-set collection primitive before AoC consumes it. Adding 5
// twice + 3 once => 2 distinct keys. <set!> discharged by free.
import std/io
import std/set

std/set:new()
| set s |> std/set:add(s, 5) |> std/set:add(s, 5) |> std/set:add(s, 3) |> std/set:count(s)
    | count n |> std/io:print.ln("{{ n:d }}") |> std/set:free(s)
| err e |> std/io:print.ln("ERR {{ e:s }}")
