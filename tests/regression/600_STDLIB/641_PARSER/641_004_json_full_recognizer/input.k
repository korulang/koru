// The full-JSON flagship: every JSON shape — nested objects, arrays, numbers
// with fraction+exponent, strings, true/false/null — recognized by a pure
// std/parser PEG grammar. Pins the shapes JSON forced out of cut-1:
// duplicate-head ordered choice (object/array/members/elements each need
// "long form | short form" starting on the same head — comptime branch data
// consumed by the grammar transform, ruled 2026-07-17), right-recursive
// lists standing in for repetition, and a zero-length `*` terminal (ws)
// composed mid-chain. Values are spans in cut 1: the top rule produces the
// whole consumed text.
import std/parser
import std/io

[with]std/parser:grammar(json)
! value v |> match(v)
    | `"([^"\\]|\\.)*"` s -> s
    | `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?` n -> n
    | `true|false|null` k -> k
    | object o -> o
    | array a -> a
! string s |> match(s)
    | `"([^"\\]|\\.)*"` x -> x
! pair p |> match(p)
    | string s |> lit(":") |> sub(ws): w |> sub(value): v
! members m |> match(m)
    | pair p |> lit(",") |> sub(ws): w |> sub(members): r
    | pair p -> p
! object o |> match(o)
    | `\{` _ |> sub(members): m |> lit("}")
    | `\{` _ |> lit("}")
! elements e |> match(e)
    | value v |> lit(",") |> sub(ws): w |> sub(elements): r
    | value v -> v
! array a |> match(a)
    | `\[` _ |> sub(elements): e |> lit("]")
    | `\[` _ |> lit("]")
! ws w |> match(w)
    | `[ \t]*` s -> s

std/parser:parse("{\"a\":[1,2.5e3,true],\"b\":{\"c\":null},\"d\":\"x y\",\"e\":[]}", grammar: json)
| value v |> std/io:print.ln("ok {{ v:s }}")
| parse-error { line, col, expected, found } |> std/io:print.ln("err {{ line:d }}:{{ col:d }} expected {{ expected:s }} found {{ found:s }}")

std/parser:parse("{\"a\": [1, 2], \"b\": null}", grammar: json)
| value v |> std/io:print.ln("ok {{ v:s }}")
| parse-error { line, col, expected, found } |> std/io:print.ln("err {{ line:d }}:{{ col:d }} expected {{ expected:s }} found {{ found:s }}")

std/parser:parse("{\"a\":[1,}", grammar: json)
| value v |> std/io:print.ln("ok {{ v:s }}")
| parse-error { line, col, expected, found } |> std/io:print.ln("err {{ line:d }}:{{ col:d }} expected {{ expected:s }} found {{ found:s }}")
