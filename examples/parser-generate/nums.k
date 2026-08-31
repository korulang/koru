import std/parser

// A tiny grammar: signed integers and nested bracket arrays of them.
// Exercises every codegen primitive — a pattern terminal (DFA), a literal
// token, a sub-rule call, a produce (`->`), and recursion (array -> value
// -> array). This is the grammar `generate` lowers to a standalone parser.
[with]std/parser:grammar(nums)
! value v |> match(v)
    | `-?[0-9]+` n -> n
    | array a -> a
! array a |> match(a)
    | `\[` _ |> sub(value): v |> lit("]") -> v
