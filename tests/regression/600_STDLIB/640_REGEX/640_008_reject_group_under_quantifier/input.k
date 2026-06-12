// Cut-2 restriction (same doctrine as backrefs): no capture groups under
// quantifiers — a repeated group has no single span, and silently keeping
// the last iteration is the trap every regex engine apologizes for.
// Rejected loudly at the match site.
import std/io
import std/regex

std/regex:match("aaa")
| `(?<x>a)+` { x } |> std/io:print.ln("{{ x:s }}")
| no-match |> std/io:print.ln("no")
