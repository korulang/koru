// CHAINED bind→produce subflow: the body is a `|>` pipeline of bare-return
// sub-calls, each binding its result, and the tail produces with `->`:
//   ~combo = a(x): r1 |> b(x: r1): r2 -> r2
// This is the metacircular `frontend` pipeline's exact shape (a chain of
// `-> CompilerContext` passes). The single-step form (020_029) works; the
// chained form currently drops the trailing `-> r2` produce (the inline-
// continuation path doesn't capture it), so the handler falls off its end.
// PIN: must produce r2 (= a then b: (5+1)+10 = 16).
import std/io

pub tor a { x: i64 } -> i64
a -> x + 1

pub tor b { x: i64 } -> i64
b -> x + 10

pub tor combo { x: i64 } -> i64
combo = a(x): r1 |> b(x: r1): r2 -> r2

combo(x: 5): out |> std/io:print.ln("{{ out:d }}")
