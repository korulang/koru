// Test: String ownership transitions and append
import std/string
import std/io

std/string:from-page(text: "hello")
| ok s |> std/string:take(s): owned |> std/string:append(s: owned, text: " world")
        | ok |> std/io:print.ln("{{ owned:S }}") |> std/string:free(s: owned)
        | err _ |> std/string:free(s: owned)
| err _ |> _
