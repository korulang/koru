// std/switch:char single-char dispatch. Two literal arms plus no-match;
// the first matching arm wins and binds the payload.
import std/switch
import std/io

std/switch:char('a')
| `a` _ |> std/io:print.ln("got-a")
| `b` _ |> std/io:print.ln("got-b")
| no-match |> std/io:print.ln("other")
