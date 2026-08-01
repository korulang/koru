// PINS: a comptime transform at the ROOT of a store lifecycle arm body emits
// its expansion.
//
// The arm body is walked depth-first, so a transform sitting at its root fires
// BEFORE the store declaration transforms, and leaves its expansion on the
// invocation (`Invocation.inline_body`). The store then rebuilds that body as
// the root of a synthesized flow — and a flow root is emitted from
// `Flow.inline_body`, while only a nested continuation is emitted from the
// invocation's slot. The two slots are the shape this test guards: carry the
// expansion across the rebuild, or the emitter falls through to a plain handler
// call.
//
// `! discharge` is the IN-FILE CONTROL and pins the other position: its
// `print.ln` sits one link down a chain, so it is emitted from the nested slot.
// Both arms print, and each reaches the emitter by a different route.
//
// `std/io:print`/`print.ln` are the sharp probe for this because they reroute
// to `print.impl` for shape checking (io.kz:14). An unemitted expansion still
// leaves a real event and a real handler behind — so the failure mode this pins
// is SILENCE, not a diagnostic, and is indistinguishable at the source from an
// arm that ran.

import std/io
import std/store
import app/lib/src

std/store:new(batch, capacity: 2) { *app/lib/src:Src<live!> }
! inserted _ |> std/io:print.ln("arm inserted")
! discharge s |> app/lib/src:close(s): id |> std/io:print.ln("arm discharge {{ id:d }}")

std/io:print.ln("start")
app/lib/src:open(id: 9, work: 1): a |> std/store:insert(batch) { a }
| row _ |> std/io:print.ln("inserted")
| full f |> app/lib/src:close(s: f): id |> std/io:print.ln("full {{ id:d }}")
