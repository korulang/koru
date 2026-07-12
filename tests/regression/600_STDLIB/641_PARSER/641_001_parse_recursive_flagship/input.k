// std/parser cut-1 flagship (docs/STD_PARSER_SKETCH.md, concept
// frag-parser-library-peg-on-two-glyphs; surface ratified 2026-07-12 walk).
// A grammar is a PROTOCOL: rules are effect arms binding a cursor; each
// rule's body is ordinary code whose common picker is the EXPLICIT
// `std/parser:match(cursor)` — ordered choice over patterned branches,
// first-match-wins (the regex-match semantics of 640_001). A `->` arm is a
// PATTERNED RETURN: the input selects which value the rule produces.
// Sequence is the chain: `sub(<rule>): v` demands a sub-rule, `lit("...")`
// consumes a literal token. Recursion is exercised as value → array → value.
// The parse must consume the whole input; `parse-error` carries line/col +
// expected/found. Values are text slices in cut 1.
import std/parser
import std/io

std/parser:grammar(nums)
! value v |> std/parser:match(v)
    | `-?[0-9]+` n -> n
    | array a -> a
! array a |> std/parser:match(a)
    | `\[` _ |> std/parser:sub(value): v |> std/parser:lit("]") -> v

std/parser:parse("[42]", grammar: nums)
| value v |> std/io:print.ln("v={{ v:s }}")
| parse-error { line, col, expected, found } |> std/io:print.ln("err {{ line:d }}:{{ col:d }} expected {{ expected:s }} found {{ found:s }}")
