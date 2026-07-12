// Pins the left-recursion wall: a rule that can reach itself before consuming
// any input would recurse forever at runtime, so the parse transform rejects
// it at COMPILE TIME, by name, with the rewrite in the message (put a
// consuming element first). `expr -> expr ...` is the canonical offender;
// packrat/left-recursion support, if it ever lands, arrives under this same
// surface and flips this pin deliberately.
import std/parser
import std/io

std/parser:grammar(math)
! rule expr
    | expr e -> e
    | `[0-9]+` n -> n

std/parser:parse("1", grammar: math)
| expr v |> std/io:print.ln("v={{ v:s }}")
| parse-error { line, col, expected, found } |> std/io:print.ln("err {{ line:d }}:{{ col:d }} {{ expected:s }} {{ found:s }}")
