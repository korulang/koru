// PIN (auto-discharge): auto-disposal inserts `free(s)` at scope exit, so a
// locally-owned `<view!>` String never needs a manual discharge. `free` is the
// sole VOID terminal disposer; `take` is non-void (it issues `instance!`) so the
// void-only auto-insert rule excludes it, leaving `free` unambiguous.
//
// This is 610_008_parse_int VERBATIM minus the trailing `|> std/string:free(s)`.
// 610_008 is green WITH the explicit free; this is green WITHOUT it because the
// auto-disposer now inserts `free`.
import std/string
import std/io

std/string:from-page(text: "42")
| ok s |> std/string:parse-int(s)
    | ok n  |> std/io:print.ln("{{ n:d }}")
    | err e |> std/io:print.ln("{{ e:s }}")
| err _ |> _
