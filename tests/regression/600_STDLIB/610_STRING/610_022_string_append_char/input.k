// append-char / pop-char — TUI keystrokes feed a u8, not a string literal.
import std/io
import std/string

std/string:from-page(text: "ab")
| ok a |> std/string:take(s: a): s |> std/string:append-char(s, ch: 99)
    | ok |> std/string:append-char(s, ch: 100)
        | ok |> std/string:pop-char(s) |> std/string:read(s): text
            |> std/io:print.ln("{{ text:s }}") |> std/string:free(s)
        | err _ |> std/string:free(s)
    | err _ |> std/string:free(s)
| err _ |> _
