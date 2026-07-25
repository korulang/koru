// Pins BREADTH: a rule that names several parts keeps them ALL as kids, in
// source order — the node is a tree, not a chain. `pair` binds its head digit
// and a `sub(num)`, with no `->` to single one out, so both survive and
// `render` shows two children under one tag. Before N-kids the wrapper held
// exactly one child and this rendered as a single collapsed span.
//
// depth is 1 + the DEEPEST kid (not the first): head `3` is a bare leaf at
// depth 0, `num(4)` is depth 1, so `pair` is depth 2.
import std/parser
import std/io

[with]std/parser:grammar(pairs)
! pair p |> match(p)
    | `[0-9]+` a |> lit(":") |> sub(num): b
! num n |> match(n)
    | `[0-9]+` d -> d

std/parser:parse("3:4", grammar: pairs)
| pair { render, depth, text } |> std/io:print.ln("{{ render:s }} depth={{ depth:d }} text={{ text:s }}")
| parse-error { line, col, expected, found } |> std/io:print.ln("err {{ line:d }}:{{ col:d }} {{ expected:s }} {{ found:s }}")
