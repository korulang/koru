// DESIGN PIN — std/parser cut-1 flagship (docs/STD_PARSER_SKETCH.md, concept
// frag-parser-library-peg-on-two-glyphs). Pins the surface thesis: PEG on the
// two glyphs — ordered choice = branch dispatch (first-match-wins, the
// regex-match semantics of 640_001), sequence = the chain (`|>` consumes,
// `->` produces). Terminals are std/regex pattern branches unchanged
// (640_001/003 forms). The ONE new construct this library forces: NAMED rules
// with branch bodies (`! rule <name>`) — required by recursion, exercised
// below as value → array → value. `parse-error` carries line/col from day one.
// Surface PROVISIONAL: the std/parser vocabulary (grammar/rule/expect/parse)
// is the design target; every terminal, chain, and branch form is corpus.
import std/parser
import std/io

std/parser:grammar(nums)
! rule value
    | `-?[0-9]+` n -> n
    | array a -> a
! rule array
    | `\[` |> value(): v |> expect(`\]`) -> v

std/parser:parse("[42]", grammar: nums)
| value v |> std/io:print.ln("v={{ v:s }}")
| parse-error { line, col, expected, found } |> std/io:print.ln("err {{ line:d }}:{{ col:d }} expected {{ expected:s }} found {{ found:s }}")
