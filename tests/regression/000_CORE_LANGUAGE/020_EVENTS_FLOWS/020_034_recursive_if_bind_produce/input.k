// RECURSIVE value event through `if` + bind-then-produce — the full part-1
// shape of the single-return-form endeavor:
//   digitsum = if(base) | then -> x | else |> digitsum(...): rest -> g(rest)
// The else arm chains a recursive call, binds its bare result `: rest`, and
// produces with `->` — the branch-arm twin of the subflow-head produce
// (020_029) and the flow-level chain-tail produce (020_030). The parser used
// to swallow the `-> expr` after the bind silently (return_binding kept,
// produce dropped, handler fell off its end).
// This is THE digitsum recursion: scalar `Output = i64`, no tag union — the
// single-variant union carried the 2.9x-behind-C recursion gap.
import std/io

tor digitsum { n: i64 } -> i64
digitsum = if(n < 10)
| then -> n
| else |> digitsum(n: @divTrunc(n, 10)): rest -> rest + @mod(n, 10)

digitsum(n: 9875): d |> std/io:print.ln("{{ d:d }}")
digitsum(n: 7): e |> std/io:print.ln("{{ e:d }}")
