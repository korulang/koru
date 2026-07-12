// Pins the parse-error contract: the error carries the FURTHEST failure
// position as line/col (newline-counted at the splice), what was expected
// there (the terminal's pattern text or the rule name), and what was found
// (one byte, or "end of input"). Input "[42" commits into the array
// alternative, consumes `[` and the number, then dies wanting `\]` at 1:4
// with nothing left — the committed-path error, not "no alternative at 0".
import std/parser
import std/io

std/parser:grammar(nums)
! rule value
    | `-?[0-9]+` n -> n
    | array a -> a
! rule array
    | `\[` _
        | value v
            | `\]` _ -> v

std/parser:parse("[42", grammar: nums)
| value v |> std/io:print.ln("v={{ v:s }}")
| parse-error { line, col, expected, found } |> std/io:print.ln("err {{ line:d }}:{{ col:d }} expected {{ expected:s }} found {{ found:s }}")
