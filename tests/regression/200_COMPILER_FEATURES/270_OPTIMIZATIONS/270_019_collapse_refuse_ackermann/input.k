// PIN (collapse-recursion pass, WAY-TWO leg — CONTROL): ackermann is R1's
// structural twin — nested sibling-fed calls — but the `n: inner` bind in
// the outer call is a sibling RESULT, not a param-minus-constant, so no
// measure decreases on all self-call sites. The pass must refuse: no
// __koru_collapse_ marker anywhere in the emitted Zig. Output stays 9.
import std/io

pub tor ack { m: i64, n: i64 } -> i64

ack = if(m == 0)
| then -> n + 1
| else |> if(n == 0)
    | then |> ack(m: m - 1, n: 1): v -> v
    | else |> ack(m, n: n - 1): inner |> ack(m: m - 1, n: inner): v -> v

ack(m: 2, n: 3): r |> std/io:print.ln("{{ r:d }}")
