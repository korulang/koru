// scan, groupless: extract every run of digits as an effect stream. No named
// groups — the `!` branch carries the matched text span (the predicate/text path,
// complementing 640_011's named-group destructure). Leftmost-longest: "12" and
// "345", not single digits.
import std/io
import std/regex

std/regex:scan(input: "a12b345c")
! `[0-9]+` n |> std/io:print.ln("n={{ n:s }}")
| done |> std/io:print.ln("done")
