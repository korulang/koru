// NESTING SWEEP — strbranch at POSITION 4 (under a FOR-EACH branch).
// The strbranch construct is nested under the per-iteration effect branch of
// for(0..3) (! each _). It fires three times, printing "ok" and freeing its
// own view each iteration.
import std/io
import std/string

for(0..3)
! each _ |> std/string:from-page(text: "x")
    | ok s |> std/io:print.ln("ok") |> std/string:free(s)
    | err _ |> std/io:print.ln("err")
| done |> _
