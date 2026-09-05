// Test: Basic string creation and handle print (610_007: `read` retired —
// consumers take the handle; `{{ s:S }}` reads it inside the step)
import std/string
import std/io

std/string:from-page(text: "hello")
| ok s |> std/io:print.ln("{{ s:S }}") |> std/string:free(s)
| err _ |> _
