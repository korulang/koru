// Pins std/parser returning a NESTED STRUCTURE rather than a flat span: every
// rule wraps its result in `rulename(child)` in the codegen, so the nesting
// survives the parse walk instead of collapsing to the innermost span. `[[7]]`
// returns value(array(value(array(value(7))))) — the children are kept, not
// flattened. The `{ tag, val }` payload carries which branch matched (tag)
// beside the built tree (val), delivered on the success branch the same way
// parse-error already delivers its record. Rendered as text here; a typed
// *Node payload is the same walk-and-keep-children mechanism, struct not string.
import std/parser
import std/io

[with]std/parser:grammar(nums)
! value v |> match(v)
    | `-?[0-9]+` n -> n
    | array a -> a
! array a |> match(a)
    | `\[` _ |> sub(value): v |> lit("]") -> v

std/parser:parse("7", grammar: nums)
| value { tag, val } |> std/io:print.ln("top={{ tag:s }} tree={{ val:s }}")
| parse-error { line, col, expected, found } |> std/io:print.ln("err {{ line:d }}:{{ col:d }} {{ expected:s }} {{ found:s }}")

std/parser:parse("[7]", grammar: nums)
| value { tag, val } |> std/io:print.ln("top={{ tag:s }} tree={{ val:s }}")
| parse-error { line, col, expected, found } |> std/io:print.ln("err {{ line:d }}:{{ col:d }} {{ expected:s }} {{ found:s }}")

std/parser:parse("[[7]]", grammar: nums)
| value { tag, val } |> std/io:print.ln("top={{ tag:s }} tree={{ val:s }}")
| parse-error { line, col, expected, found } |> std/io:print.ln("err {{ line:d }}:{{ col:d }} {{ expected:s }} {{ found:s }}")
