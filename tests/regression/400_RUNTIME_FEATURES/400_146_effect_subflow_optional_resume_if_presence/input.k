// OPTIONAL RESUME ARMS, the presence test (`if(ask)`) — designed 2026-07-03.
// An arm that RESUMES a value (`! ?ask i64 -> i64`) cannot lower to a no-op
// when unhandled (there is no value to fabricate), so the producer must be
// able to DECIDE whether to fire: inside the declaring event's impl, the
// arm's bare name in `if`'s condition position is a comptime PRESENCE test —
// "did this consumer install the handler." Same `if(...) | then | else`
// construct as 010_008; the only novelty is the condition's expression kind.
// Inside `| then` the arm is fireable exactly like a required arm (the
// bind-then-construct body is 400_132's shape); in `| else` the producer
// writes its own fallback — explicitly, no silent default.
//
// This consumer OMITS the handler, so the comptime branch resolves to
// `| else` and the program prints 0. The handled twin behaves like 400_132.
import std/io

pub event query { q: i64 }
! ?ask i64 -> i64
| done i64

query = if(ask)
| then |> ask(q): a => done a
| else => done 0

query(q: 41)
| done r |> std/io:print.ln("{{ r:d }}")
