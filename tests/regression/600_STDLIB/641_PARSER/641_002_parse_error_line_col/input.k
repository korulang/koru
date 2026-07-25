// Pins the parse-error contract: the error carries the FURTHEST failure
// position as line/col (newline-counted at the splice), what was expected
// there (the terminal's pattern/literal text or the rule name), and what was
// found (one byte, or "end of input"). Input "[42" enters the array
// alternative, consumes `[` and the number, then dies wanting the `]`
// literal at 1:4 with nothing left — the deep-path error, not "no
// alternative at 0".
import std/parser
import std/io

std/parser:grammar(nums)
! value v |> std/parser:match(v)
    | `-?[0-9]+` n -> n
    | array a -> a
! array a |> std/parser:match(a)
    | `\[` _ |> std/parser:sub(value): v |> std/parser:lit("]") -> v

std/parser:parse("[42", grammar: nums)
| value { leaf } |> std/io:print.ln("v={{ leaf:s }}")
| parse-error { line, col, expected, found } |> std/io:print.ln("err {{ line:d }}:{{ col:d }} expected {{ expected:s }} found {{ found:s }}")
