// NESTING SWEEP — strbranch at POSITION 0 (flow-head BASELINE).
// The construct IS the top-level flow head: no enclosing continuation.
// Must work; it is the baseline every nested position is measured against.
import std/io
import std/string

std/string:from-page(text: "x")
| ok s |> std/io:print.ln("ok") |> std/string:free(s)
| err _ |> std/io:print.ln("err")
