// NESTING SWEEP — strbranch at POSITION 2 (under an OBLIGATION branch).
// The outer `ok s` carries a String<view!> obligation; the nested strbranch
// construct must discharge that outer `s` (std/string:free(s)) on EVERY
// terminal path of the construct, alongside freeing its own inner view `s2`.
// KORU030 fires if any terminal leaks `s`.
import std/io
import std/string

std/string:from-page("x")
| ok s |> std/string:from-page("y")
    | ok s2 |> std/io:print.ln("ok") |> std/string:free(s2) |> std/string:free(s)
    | err _ |> std/io:print.ln("err") |> std/string:free(s)
| err _ |> _
