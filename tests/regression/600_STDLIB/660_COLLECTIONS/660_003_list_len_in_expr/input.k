// RED PIN — collection value in an EXPRESSION in an event call. PROPOSED.
// `xs.len + 10` is an opaque expression passed to print.ln. Void push chains `|>`.
import std/io
import std/list

std/list:new(i64)
| list xs |> std/list:push(xs, 7) |> std/io:print.ln("{{ xs.len + 10:d }}")
| err e |> std/io:print.ln("ERR {{ e:s }}")
