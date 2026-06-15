// Index past the end takes the out-of-bounds branch.
import std/io
import std/list

std/list:new(i64)
| list xs |> std/list:push(xs, 10) |> std/list:get(xs, 5)
    | item v |> std/io:print.ln("at 5: {{ v:d }}") |> std/list:free(xs)
    | out-of-bounds |> std/io:print.ln("oob") |> std/list:free(xs)
| err e |> std/io:print.ln("ERR {{ e:s }}")
