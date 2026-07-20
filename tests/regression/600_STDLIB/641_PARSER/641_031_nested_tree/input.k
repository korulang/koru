// Pins std/parser returning a real TYPED NODE graph, not a flat span and not a
// string: each rule builds a *Node { tag, text, kids } wrapping the child node it
// kept, so the parse walk assembles a tree you traverse in code. `depth` and
// `leaf` in the output are computed by recursively walking node.kids / node.text
// (proof it is a graph, not text). `[[7]]` -> value(array(value(array(value(7)))))
// depth=5 leaf=7. The success branch receives the walked result the same way
// parse-error already delivers its typed record.
import std/parser
import std/io

[with]std/parser:grammar(nums)
! value v |> match(v)
    | `-?[0-9]+` n -> n
    | array a -> a
! array a |> match(a)
    | `\[` _ |> sub(value): v |> lit("]") -> v

std/parser:parse("7", grammar: nums)
| value { render, depth, leaf } |> std/io:print.ln("{{ render:s }} depth={{ depth:d }} leaf={{ leaf:s }}")
| parse-error { line, col, expected, found } |> std/io:print.ln("err {{ line:d }}:{{ col:d }} {{ expected:s }} {{ found:s }}")

std/parser:parse("[7]", grammar: nums)
| value { render, depth, leaf } |> std/io:print.ln("{{ render:s }} depth={{ depth:d }} leaf={{ leaf:s }}")
| parse-error { line, col, expected, found } |> std/io:print.ln("err {{ line:d }}:{{ col:d }} {{ expected:s }} {{ found:s }}")

std/parser:parse("[[7]]", grammar: nums)
| value { render, depth, leaf } |> std/io:print.ln("{{ render:s }} depth={{ depth:d }} leaf={{ leaf:s }}")
| parse-error { line, col, expected, found } |> std/io:print.ln("err {{ line:d }}:{{ col:d }} {{ expected:s }} {{ found:s }}")
