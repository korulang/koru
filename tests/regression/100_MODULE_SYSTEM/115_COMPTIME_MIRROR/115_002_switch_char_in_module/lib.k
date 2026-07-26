import std/switch
import std/io

pub tor run {}
run = std/switch:char('a')
| `a` _ |> std/io:print.ln("got-a")
| `b` _ |> std/io:print.ln("got-b")
| no-match |> std/io:print.ln("other")
