// PINS: an UNCLOSED paren in a capture-write field value is refused, at the
//       author's own line. Sibling of 100_081/082 (stray CLOSERS in call args)
//       on a different path — the capture-family field-value scan. Here the
//       `@as(...` is never closed.
//
// The guarded property is that the imbalance is NAMED. The failure mode this
// pin exists against is silent absorption: a malformed field value that
// produces an empty program and exits 0 reads as "emission emits empty", and
// cost real debugging time on an AoC conway expression.
import std/io

capture { x: 0[i64] }
! as a |> captured { x: a.x + @as(i64, @intFromBool((1 + 2) == 3) }
| captured r |> std/io:print.ln("{{ r.x:d }}")
