// Pins duplicate-head ordered choice: two alternatives of one rule may begin
// with the SAME element — try in order, first success wins, backtrack between
// them. This is the PEG list idiom (`item "," rest | item`) and it is
// essential in cut 1: with no epsilon rules it cannot be left-factored away.
// Same-named branches are comptime data consumed by the grammar transform
// (ruled 2026-07-17) — the frontend never judges them as dispatch ambiguity.
import std/parser
import std/io

[with]std/parser:grammar(csv)
! list l |> match(l)
    | `[0-9]+` n |> lit(",") |> sub(list): r
    | `[0-9]+` n -> n

std/parser:parse("7,8,9", grammar: csv)
| list { text } |> std/io:print.ln("ok {{ text:s }}")
| parse-error { line, col, expected, found } |> std/io:print.ln("err {{ line:d }}:{{ col:d }} expected {{ expected:s }} found {{ found:s }}")
