// Pins: the head label on a bare-return tor is the SAME binding sugar inside a
// subflow BODY that 210_195 pins at the flow head. `tick = now() | t n |>` must
// bind n to now's `-> i128` result.
//
// The two positions are emitted by different machinery, and only the head knows
// this. The subflow body's return-switch path emits a tag dispatch over the
// returned scalar — `switch (result) { .t => |n| ... }` where result is an i128 —
// and the author is handed Zig about a file they never opened, which is the exact
// leak 210_195's own comment names as the guarded seam.
//
// Sibling of the head-position fix: the flow head learned the callee's bare
// return through `callee_bare_return` in emitContinuationList; the subflow body
// path (emitSubflowContinuationsWithDepth) has no equivalent.
import std/io
import std/time
import std/control

pub tor tick { deadline: i128 }
| live i128
| expired i128

tick = std/time:now()
| t n |> if(n < deadline)
    | then => live n
    | else => expired n

tick(deadline: 1)
| live x |> std/io:print.ln("live")
| expired y |> std/io:print.ln("expired {{ y:d }}")
