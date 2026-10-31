// Pins profiler x [parallel]for: under --profile the tap wrap around each
// branch handler must preserve the handler's `!` effect kind, so the
// parallel lowering's partition + additive combine survives instrumentation.
// The checksum is the serial fold's answer; the trace carries the loop's
// transitions on a closed JSON stream.
import std/io
[profile]import std/profiler

capture { acc: 0[i64] }
! as a |> [parallel]for(1..1001)
    ! each i |> captured { acc: a.acc + @as(i64, @intCast(i)) }
| captured r |> std/io:print.ln("{{ r.acc:d }}")
