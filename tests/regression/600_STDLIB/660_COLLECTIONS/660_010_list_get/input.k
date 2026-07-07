// Random access by index. Push 10,20,30; get index 1 → 20.
import std/io
import std/list

std/list:new(i64)
| list xs |> std/list:push(xs, v: 10) |> std/list:push(xs, v: 20) |> std/list:push(xs, v: 30) |> std/list:get(xs, i: 1)
    | item v |> std/io:print.ln("at 1: {{ v:d }}") |> std/list:free(xs)
    | out-of-bounds |> std/io:print.ln("oob") |> std/list:free(xs)
| err e |> std/io:print.ln("ERR {{ e:s }}")
