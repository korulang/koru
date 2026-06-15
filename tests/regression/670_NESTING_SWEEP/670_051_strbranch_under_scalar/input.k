// NESTING SWEEP — strbranch at POSITION 1 (under a SCALAR branch).
// The strbranch construct is nested under a no-obligation scalar continuation
// (args:count | count _). Success path prints "ok" once and frees its own view.
import std/io
import std/string
import std/args

std/args:count()
| count _ |> std/string:from-page("x")
    | ok s |> std/io:print.ln("ok") |> std/string:free(s)
    | err _ |> std/io:print.ln("err")
