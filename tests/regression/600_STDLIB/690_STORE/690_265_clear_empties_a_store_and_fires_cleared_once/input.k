// PINS: `std/store:clear` — the bulk twin of `take`.
//
// EACH REMOVAL VERB HAS ITS OWN ARM. `take` removes one row and fires
// `! removed`; `clear` empties the store and fires `! cleared` ONCE, binding
// how many rows went. Neither fires the other's arm, and that is the whole
// point: an emptied store that hands its observer a thousand per-row events
// has not saved the observer anything, and the observer is where the cost is
// (measured at 92% of a thousand-row clear in the DOM gauntlet, where every
// event went looking for its own page element).
//
// The count is all an aggregate arm can be handed. By the time it fires the
// store is empty, so there is no row left to read — which is also why it is
// spelled in the past tense.
//
// HANDLES GO STALE ACROSS IT, and this is the part a bulk reset gets wrong if
// written carelessly. The brand is a compile-time constant naming WHICH STORE
// issued a handle, so bumping it would break cross-store discrimination and
// invalidate nothing; the generation of every live slot is bumped instead.
// 690_266's sibling proves the trap still fires; here the pin is that a clear
// is a real emptying — the next insert starts from an empty store and the
// counter the aggregate arm maintains agrees.
import std/io
import std/store

std/store:new(tally) { gone: 0[i64], live: 0[i64] }

std/store:new(rows, capacity: 8) { v: i64 }
! inserted _ |> std/store:stored { tally.live: tally.live + 1 }
! cleared n |> std/store:stored { tally.gone: tally.gone + n } |> std/store:stored { tally.live: 0 }

std/store:insert(rows) { v: 10 }
    | row _ |> _
    | full |> _
std/store:insert(rows) { v: 20 }
    | row _ |> _
    | full |> _
std/store:insert(rows) { v: 30 }
    | row _ |> _
    | full |> _

std/io:print.ln("live {{ tally.live:d }}")

// The chain tail joins the rewritten call, the contract stripe and stored
// carry — a clear does not swallow what follows it.
std/store:clear(rows) |> std/io:print.ln("after first clear: gone {{ tally.gone:d }} live {{ tally.live:d }}")

// A cleared store is an EMPTY store, not a broken one: it takes rows again.
std/store:insert(rows) { v: 40 }
    | row _ |> _
    | full |> _
std/io:print.ln("refilled to {{ tally.live:d }}")
std/store:clear(rows) |> std/io:print.ln("after second clear: gone {{ tally.gone:d }} live {{ tally.live:d }}")
