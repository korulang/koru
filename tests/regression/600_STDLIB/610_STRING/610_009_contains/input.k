// Test: substring containment — scalar yes/no dispatch (FRONTIERS gap 4).
// No borrow: the result is a branch tag, the needle is a caller-owned input.
import std/string
import std/io

std/string:from-page(text: "hello world")
| ok s |> std/string:contains(s, needle: "world")
    | yes |> std/io:print.ln("found") |> std/string:free(s)
    | no  |> std/io:print.ln("absent") |> std/string:free(s)
| err _ |> _
