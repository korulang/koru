import std/string
import std/io

std/string:from-page(text: "x")
| ok s |> std/string:take(s): owned |> std/io:print.ln("instance dropped")
| err _ |> _
