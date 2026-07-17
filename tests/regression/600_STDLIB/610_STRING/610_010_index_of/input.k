// Test: index-of — found usize / not-found (FRONTIERS gap 4, scalar return).
import std/string
import std/io

std/string:from-page(text: "hello")
| ok s |> std/string:index-of(s, needle: "lo")
    | found i   |> std/io:print.ln("{{ i:d }}") |> std/string:free(s)
    | not-found |> std/io:print.ln("absent") |> std/string:free(s)
| err _ |> _
