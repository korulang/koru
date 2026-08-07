// PINS: a ROW-BINDING read in an `if` CONDITION under a rule arm lowers to
// the column read, both targets, nested depth included. Two mechanisms meet
// here: the per-call template pass froze the if's rendered body — condition
// text included — before store:create ran (690_074's freeze), so the row
// rewrite must reach INTO the frozen inline_body; and when the if is the
// arm's body ROOT, the transplant makes it the qbody flow's head, whose
// emitter reads the FLOW's inline_body — the rendered template rides the
// promotion, not a dispatch to an emitted `if_event` (none exists).
// The same read in guards, call args, stored writes and fmt interpolations
// was already covered; the if condition was the position that missed.

import std/io
import std/store
import std/control

std/store:new(rows, capacity: 4) { id: i64 }

std/store:insert(rows) { id: 7 }

std/store:rule(rows)
! row e |> if(e.id > 3)
    | then |> if(e.id == 7)
        | then |> std/io:print.ln("deep hit {{ e.id:d }}")
        | else |> std/io:print.ln("deep miss")
    | else |> _
