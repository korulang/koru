// A list-derived scalar used inside an interpolation expression. `list:len`
// yields a scalar `n`; `{{ n + 10:d }}` exercises arithmetic in the expression
// position. Reads go through the `list:len` event, not `.len` field-paste.
import std/io
import std/list

std/list:new(i64)
| list xs |> std/list:push(xs, v: 7) |> std/list:len(xs): n |> std/io:print.ln("{{ n + 10:d }}") |> std/list:free(xs)
| err e |> std/io:print.ln("ERR {{ e:s }}")
