import std/io
import std/list

pub tor run {}
run = std/list:new(i64)
| list xs |> std/list:push(xs, v: 7) |> std/list:len(xs): n |> std/io:print.ln("{{ n + 10:d }}") |> std/list:free(xs)
| err e |> std/io:print.ln("ERR {{ e:s }}")
