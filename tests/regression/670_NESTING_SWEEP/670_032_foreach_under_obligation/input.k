// NESTING SWEEP — foreach under an OBLIGATION branch (position 2).
// The construct is nested under std/string:from-page("x")'s `| ok s` branch,
// which binds an obligation view `s` that must be freed on EVERY terminal of
// the nested construct. The foreach's only terminal is `| done`, so `s` is
// discharged there; the sibling `| err _` discharges nothing (no binding).
// Grounded on 630_002 (read-lines under from-page view! with free on terminal).
import std/io
import std/string

std/string:from-page(text: "x")
| ok s |> for(0..3)
    ! each _ |> _
    | done |> std/io:print.ln("done") |> std/string:free(s)
| err _ |> _
