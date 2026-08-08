// PINS: `[id]` on a LIFECYCLE arm — the twin of 690_246 (sweep) and 690_247
// (rule), in the two places the request block did not reach.
//
// A `! inserted` / `! removed` arm binds its row's COLUMNS by pun, and until
// now that was all it could name. So an observer outside the store — one that
// mints something per row and must find it again later — had nothing stable to
// key on: the columns are the row's DATA, and any of them may repeat.
//
// `[id]h` names the handle, and the guarantee this test exists for is that it
// is THE SAME HANDLE AT BOTH ENDS, across compaction. `take` swap-removes the
// last row into the freed slot, so the dying row's dense position is not its
// identity — `c` below physically moves when `b` dies, and its death must
// still name the handle its birth did. A registry keyed on position would
// pass every check that looks at the row SET and still address the wrong row.
//
// `! removed` fires BEFORE the swap-remove and the generation bump, so the
// dying row still resolves: this is the last moment an observer keyed on that
// handle can find its own entry to let go of.
//
// The motivating workload is the DOM gauntlet's row table, where a component
// mints an element per row and re-finding it by scanning cost 92% of a
// thousand-row clear (koru-libs dom/board/timings-2026-08-08).
import std/io
import std/store

std/store:new(log) { b: -1[i64], c: -1[i64], died: -1[i64] }

std/store:new(rows, capacity: 8) { v: i64 }
! inserted { v, [id]h } |> std/io:print.ln("born v={{ v:d }} h={{ h:d }}")
! removed { v, [id]h } |> std/store:stored { log.died: h } |> std/io:print.ln("died v={{ v:d }} h={{ h:d }}")

std/store:insert(rows) { v: 10 }
    | row _ |> _
    | full |> _
std/store:insert(rows) { v: 20 }
    | row rb |> std/store:stored { log.b: rb }
    | full |> _
std/store:insert(rows) { v: 30 }
    | row rc |> std/store:stored { log.c: rc }
    | full |> _

// b dies; c swap-moves into b's dense slot.
std/store:take(rows[log.b])
    | item _ |> _
// c dies from its NEW position; its handle is unchanged.
std/store:take(rows[log.c])
    | item _ |> _

std/io:print.ln("c handle at birth and at death agree: {{ log.c:d }} {{ log.died:d }}")
