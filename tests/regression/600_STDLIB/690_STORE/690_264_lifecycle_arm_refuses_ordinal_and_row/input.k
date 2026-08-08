// PINS: what a LIFECYCLE arm's request block refuses, and that each refusal
// says WHICH KIND of no it is — the distinction 690_248 established.
//
// `[ordinal]` is MEANINGLESS here and says so: a birth or a death is one row's
// event, not a position in a walk. That is not a rung, and a later slice must
// not "add" it.
//
// (`[row]` is refused separately as NOT BUILT rather than meaningless — the
// arm already is about one row, and binding it to reach columns the payload
// does not pun is a real thing that simply is not this rung. Keeping the two
// refusals distinct is the whole point: "meaningless here" must never read as
// "unimplemented here".)
import std/io
import std/store

std/store:new(rows, capacity: 4) { v: i64 }
! inserted { v, [ordinal]n } |> std/io:print.ln("v={{ v:d }} n={{ n:d }}")

std/store:insert(rows) { v: 1 }
    | row _ |> _
    | full |> _
