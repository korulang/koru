// pop returns the last element (LIFO) and leaves the list alive (<list!>) to be
// popped again or freed. Push 3 then 4; pop yields 4. Both pop branches discharge
// the list via free.
import std/io
import std/list

std/list:new(i64)
| list xs |> std/list:push(xs, 3) |> std/list:push(xs, 4) |> std/list:pop(xs)
    | item v |> std/io:print.ln("popped {{ v:d }}") |> std/list:free(xs)
    | empty  |> std/io:print.ln("empty") |> std/list:free(xs)
| err e |> std/io:print.ln("ERR {{ e:s }}")
