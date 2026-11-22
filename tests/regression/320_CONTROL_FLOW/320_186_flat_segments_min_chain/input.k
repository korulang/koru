// PIN: a self-call whose result feeds the next self-call, ending in a tail
// self-forward, lowers to flat continuation segments — __koru_seg_eval +
// __koru_seg_kN over a lane stack. Minimal isolate of 320_148.
import std/io

pub tor hop { n: i64 } -> i64

hop = if(n == 0)
| then -> 0
| else |> hop(n: n - 1): v |> hop(n: v): w -> w

hop(n: 3): r |> std/io:print.ln("{{ r:d }}")
