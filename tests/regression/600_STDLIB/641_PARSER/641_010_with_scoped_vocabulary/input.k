// DESIGN PIN — `[with]` scoped vocabulary resolution (ruled 2026-07-12 walk;
// concept frag-parser-library-peg-on-two-glyphs). The `[with]` annotation on
// a region invocation lets the resolver check the invoked module for
// otherwise-UNRESOLVED events in the flow's immediate lexical subtree — so a
// grammar reads as grammar (`match`, `sub`, `lit` bare) instead of plumbing.
// The ruling: unresolved-only (never shadows a resolving name), multiple
// `[with]`s allowed on a subtree, ambiguity between them forces an explicit
// pick (the keyword-implementation precedent), target derivable from the
// annotated invocation's own module. Full qualification stays the default
// everywhere else — scoped resolution is the region privilege.
import std/parser
import std/io

[with]std/parser:grammar(nums)
! value v |> match(v)
    | `-?[0-9]+` n -> n
    | array a -> a
! array a |> match(a)
    | `\[` _ |> sub(value): v |> lit("]") -> v

std/parser:parse("[7]", grammar: nums)
| value v |> std/io:print.ln("v={{ v:s }}")
| parse-error { line, col, expected, found } |> std/io:print.ln("err {{ line:d }}:{{ col:d }} expected {{ expected:s }} found {{ found:s }}")
