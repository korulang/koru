import std/parser
import std/io

[with]std/parser:grammar(csv)
! list l |> match(l)
    | `[0-9]+` n |> lit(",") |> sub(list): r
    | `[0-9]+` n -> n

pub tor run {}
run = std/parser:parse("7,8,9", grammar: csv)
| list { text } |> std/io:print.ln("ok {{ text:s }}")
| parse-error { line, col, expected, found } |> std/io:print.ln("err {{ line:d }}:{{ col:d }} expected {{ expected:s }} found {{ found:s }}")
