// scan over input with zero matches: the `!` branch never fires, `| done` runs
// exactly once. Pins the empty-stream + done path.
import std/io
import std/regex

std/regex:scan(input: "no digits here")
! `[0-9]+` n |> std/io:print.ln("n={{ n:s }}")
| done |> std/io:print.ln("done")
