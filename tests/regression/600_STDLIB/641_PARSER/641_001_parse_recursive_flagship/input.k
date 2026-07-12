// std/parser cut-1 flagship (docs/STD_PARSER_SKETCH.md, concept
// frag-parser-library-peg-on-two-glyphs). Pins the surface thesis: PEG on the
// two glyphs — ordered choice = SIBLING arms (first-match-wins, the
// regex-match semantics of 640_001), sequence = NESTED arms (each level =
// "then consume"). Terminals are std/regex pattern branches unchanged
// (640_001/003 forms); rule references are bare names; recursion is exercised
// as value → array → value. The parse must consume the whole input;
// `parse-error` carries line/col + expected/found. Values are text slices in
// cut 1 (typed conversion is the regex-groups story).
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

std/parser:parse("[42]", grammar: nums)
| value v |> std/io:print.ln("v={{ v:s }}")
| parse-error { line, col, expected, found } |> std/io:print.ln("err {{ line:d }}:{{ col:d }} expected {{ expected:s }} found {{ found:s }}")
