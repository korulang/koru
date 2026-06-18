// std/string:split — effect-stream over separator-delimited pieces (the
// read-lines streaming shape, one level down). Borrowed views into the input,
// no allocation. Splitting "a, bb, ccc" on ", " fires `! piece` three times,
// then `| done` with the count. The naive-phase parsing primitive that lets
// pure Koru handle variable-arity lines (each whole piece → anchored regex).
import std/io
import std/string

std/string:split(s: "a, bb, ccc", sep: ", ")
! piece p |> std/io:print.ln("[{{ p:s }}]")
| done n |> std/io:print.ln("count={{ n:d }}")
