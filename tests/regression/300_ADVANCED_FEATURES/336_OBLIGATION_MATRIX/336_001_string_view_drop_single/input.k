import std/string
import std/io

std/string:from-page(text: "x")
| ok s |> std/io:print.ln("view dropped")
| err _ |> _
