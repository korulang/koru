// PIN (recursion-unroll pass, challenge 035 leg): non-direct recursion must
// REFUSE — silently, unchanged. The self-calls are real `fibin(...)` calls
// but they sit under a FOREIGN event's result arm (`idp`'s `| ok` branch),
// not in the impl body's own chain — the expressible form of "recursion
// dispatched through another event" (Koru has no stored event values; the
// arm-nested self-call is the same refusal class: the body's top-level
// continuation is a foreign invocation, not if/self-call/expression leaves).
// Baseline: 3 `fibin_event.handler(` sites (2 nested self + 1 main), no
// substituted guards, correct output.
import std/io

pub tor idp { n: i64 }
| ok i64
| err i64

idp = if(n < 0)
| then => err 0
| else => ok n

pub tor fibin { n: i64 } -> i64

fibin = if(n < 2)
| then -> n
| else |> idp(n)
    | ok v |> fibin(n: v - 1): a |> fibin(n: v - 2): b -> a + b
    | err _ -> 0

fibin(n: 5): r |> std/io:print.ln("{{ r:d }}")
