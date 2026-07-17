// Test: Basic string creation and read
import std/string
import std/io

std/string:from-page(text: "hello")
| ok s |> std/string:read(s): text |> std/io:print.ln("{{ text:s }}") |> std/string:free(s)
| err _ |> _
