// Cut-2 restriction: no capture groups under alternation — a group on an
// untaken branch has no span, and "empty when skipped" is a silent lie.
// Rejected loudly at the match site.
import std/io
import std/regex

std/regex:match("b")
| `a|(?<x>b)` { x } |> std/io:print.ln("{{ x:s }}")
| no-match |> std/io:print.ln("no")
