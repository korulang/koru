// pop on a fresh (empty) list takes the `empty` branch rather than `item`.
import std/io
import std/list

std/list:new(i64)
| list xs |> std/list:pop(xs)
    | item v |> std/io:print.ln("popped {{ v:d }}") |> std/list:free(xs)
    | empty  |> std/io:print.ln("empty") |> std/list:free(xs)
| err e |> std/io:print.ln("ERR {{ e:s }}")
