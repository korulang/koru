import std/string
import std/io

std/string:from-page(text: "42")
| ok s |> std/string:parse-int(s)
    | ok n  |> std/io:print.ln("{{ n:d }}")
    | err e |> std/io:print.ln("{{ e:s }}")
| err _ |> _
