// Matched-text binding — a pattern branch's binding carries the matched
// text (the `*` payload in match's contract made real). Cut-1 is FULL
// match, so the matched text is the whole input. The binding is USED in
// the body — this is the pin that the payload actually arrives (640_001
// only proves dispatch with `_` discard).
//
// Also the pure-Koru showcase: no host code anywhere, so this is a .k
// file — no `` host markers at all.
import std/regex
import std/io

std/regex:match("foo@bar")
| `[a-z]+@[a-z]+` m |> std/io:print.ln("matched: {{ m:s }}")
| `[0-9]+` _ |> std/io:print.ln("number")
| no-match |> std/io:print.ln("no-match")
