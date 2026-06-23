// std/map trunk: new → set → overwrite same key → set another → get → count → free.
// map is set-with-values (AutoHashMapUnmanaged(i64,i64)); same owned-handle model.
// set(1,10) then set(1,99) overwrites (still 1 key); set(2,20) => 2 keys. get(1)=99.
// <map!> discharged by free on both the value and missing branches.
import std/io
import std/map

std/map:new()
| map m |> std/map:set(m, k: 1, v: 10) |> std/map:set(m, k: 1, v: 99) |> std/map:set(m, k: 2, v: 20) |> std/map:get(m, k: 1)
    | value v |> std/io:print.ln("got {{ v:d }}") |> std/map:count(m): n |> std/io:print.ln("keys {{ n:d }}") |> std/map:free(m)
    | missing |> std/io:print.ln("MISSING") |> std/map:free(m)
| err e |> std/io:print.ln("ERR {{ e:s }}")
