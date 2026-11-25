// PIN (recursion-unroll pass, challenge 035 leg — CONTROL): ackermann is
// the dossier's named control. It is hanoi's structural twin — nested
// sibling-fed calls — but NO param decreases on all 3 self-call sites
// (`n==0` arm holds m; else-arm inner call holds m; outer call feeds n an
// unbounded sibling result; the m==0 produce increases n 0->1 is in the
// then-arm, not a call). Lexicographic (m,n) termination is invisible to a
// single-param witness, so the pass must refuse: the emitted shape stays the
// flat segment machine (320_148's pin) — `__koru_seg_eval` present, exactly
// 1 `ack_event.handler(` site (the external call; the impl has zero direct
// self-calls under segment lowering), no substituted guards.
import std/io

pub tor ack { m: i64, n: i64 } -> i64

ack = if(m == 0)
| then -> n + 1
| else |> if(n == 0)
    | then |> ack(m: m - 1, n: 1): v -> v
    | else |> ack(m, n: n - 1): inner |> ack(m: m - 1, n: inner): v -> v

ack(m: 2, n: 3): r |> std/io:print.ln("{{ r:d }}")
