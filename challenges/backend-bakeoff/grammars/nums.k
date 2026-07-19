import std/parser
std/parser:grammar(nums)
! value v |> std/parser:match(v)
    | `-?[0-9]+` n -> n
    | array a -> a
! array a |> std/parser:match(a)
    | `\[` _ |> std/parser:sub(value): v |> std/parser:lit("]") -> v
