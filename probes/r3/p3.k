// PROBE 3 — THE BASELINE. Two participants, one ordered pass, using only
// constructs that exist today. This is what downloads.k and kopium arrive at by
// hand; every line below the divider is what `std/pump` would have to delete.
import std/io
import std/store
import lib/srclib

// ---- the wire (already fine) --------------------------------------------
std/store:new(fast, capacity: 2) { *lib/srclib:Src<live!> }
! discharge s |> lib/srclib:close(s): id |> std/io:print.ln("retired {{ id:d }}")

std/store:new(slow, capacity: 2) { *lib/srclib:Src<live!> }
! discharge s |> lib/srclib:close(s): id |> std/io:print.ln("retired {{ id:d }}")

// ---- the scheduler, by hand ---------------------------------------------
// Two flags, exactly as d_turns.k:56 grew them.
std/store:new(ui) { live: 1[i64], retire: 0[i64] }

// One participant's pass. Written once per store, because a sweep names one
// store and nothing composes two.
tor pass-fast {}
pass-fast = std/store:sweep(fast)
! sweep s |> lib/srclib:step(s)
    ! moved i |> std/io:print.ln("fast moved {{ i:d }}")
    | running |> _
    | complete |> std/store:stored { ui.retire: 1 }

tor pass-slow {}
pass-slow = std/store:sweep(slow)
! sweep s |> lib/srclib:step(s)
    ! moved i |> std/io:print.ln("slow moved {{ i:d }}")
    | running |> _
    | complete |> std/store:stored { ui.retire: 1 }

// Ordering: `fast` before `slow` because these two lines are in that order.
// Nothing in the type system says so, and nothing would catch a swap.
tor pass {}
pass = pass-fast() |> pass-slow()

// Removal cannot happen under a sweep, so it defers — d_turns.k:141.
tor retire {}
retire = std/store:take(fast[0])
| item s |> lib/srclib:close(s): id |> std/io:print.ln("retired {{ id:d }}") |> std/store:stored { ui.retire: 0 }
| empty |> std/store:stored { ui.retire: 0 }

// ---- the program ---------------------------------------------------------
lib/srclib:open(id: 1, work: 2): a |> std/store:insert(fast) { a }
| row _ |> _
| full f |> lib/srclib:close(s: f): id |> std/io:print.ln("dropped {{ id:d }}")

lib/srclib:open(id: 2, work: 3): b |> std/store:insert(slow) { b }
| row _ |> _
| full f |> lib/srclib:close(s: f): id |> std/io:print.ln("dropped {{ id:d }}")

pass()
pass()
pass()
