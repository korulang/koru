// NESTING SWEEP — ifcond under an obligation branch (std/string:from-page).
// The view `s` is an obligation: it must be discharged with std/string:free(s)
// on EVERY terminal of the nested construct (both `then` and `else`) or KORU030.
import std/io
import std/string

std/string:from-page(text: "x")
| ok s |> if(1 == 1)
    | then |> std/io:print.ln("then") |> std/string:free(s)
    | else |> std/io:print.ln("else") |> std/string:free(s)
| err _ |> _
