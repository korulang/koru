// scan dispatches INTO each match — effect semantics. A terminal `|` pattern
// (fire-once) is the wrong kind and is rejected loudly, mirroring the orisha
// router's rejection of terminal route branches. Use `!`.
import std/io
import std/regex

std/regex:scan(input: "42")
| `[0-9]+` n |> std/io:print.ln("oops")
| done |> std/io:print.ln("done")
