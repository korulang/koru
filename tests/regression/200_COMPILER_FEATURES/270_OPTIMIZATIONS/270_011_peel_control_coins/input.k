// PIN (recursion-unroll pass, challenge 035 leg — CONTROL): coins/ways is
// excluded under the v1 predicate for TWO named reasons — (a) no single
// param decreases on both self-call sites (`amount` goes amount-c where c
// is a foreign `coin(kind)` result on site A and stays unchanged on site B;
// `kind` is unchanged on A and kind-1 on B), and (b) the body carries a
// foreign `coin()` call. v2 (lexicographic measure + positivity proof) may
// flip this test to a positive — leave that decision to the leg-4 scope
// ruling; until then the emitted shape must stay baseline: `ways_event.
// handler(` = 3 sites (2 self + 1 main), `coin_event.handler(` = 1 site
// (the call inside ways), no substituted guards.
import std/io

pub tor coin { k: i64 } -> i64

coin = if(k == 1)
| then -> 1
| else |> if(k == 2)
    | then -> 5
    | else |> if(k == 3)
        | then -> 10
        | else |> if(k == 4)
            | then -> 25
            | else -> 50

pub tor ways { amount: i64, kind: i64 } -> i64

ways = if(amount == 0)
| then -> 1
| else |> if(amount < 0)
    | then -> 0
    | else |> if(kind == 0)
        | then -> 0
        | else |> coin(k: kind): c |> ways(amount: amount - c, kind): a |> ways(amount, kind: kind - 1): b -> a + b

ways(amount: 30, kind: 3): r |> std/io:print.ln("{{ r:d }}")
