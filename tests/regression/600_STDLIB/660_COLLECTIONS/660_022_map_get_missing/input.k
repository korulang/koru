// std/map get on an absent key takes the | missing branch (not | value).
// Both branches discharge the <map!> obligation via free.
import std/io
import std/map

std/map:new()
| map m |> std/map:set(m, k: 7, v: 42) |> std/map:get(m, k: 99)
    | value v |> std/io:print.ln("got {{ v:d }}") |> std/map:free(m)
    | missing |> std/io:print.ln("none") |> std/map:free(m)
| err e |> std/io:print.ln("ERR {{ e:s }}")
