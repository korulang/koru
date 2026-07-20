// NESTING SWEEP — foreach under a STORE-WATCH arm (position 7).
// Pins that a for(0..n) ! each / | done loop composes as the body of a
// store-watch `! v x` arm — the arm whose body is SPLICED to the store's
// write sites (the "transplant purity" model, 690_046 / 670_056), not run
// at its lexical position. The splice must transplant the whole loop
// (its own ! each / | done sub-branches intact) into the write site.
// One write (`c.v: 1`) fires the watch once, so the loop's single `| done`
// terminal prints once.
// Grounded on: for-each shape 670_030/670_033; store-watch arm 670_056.
import std/io
import std/store

std/store:new(c) { v: 0[i64] }

std/store:watch(c)
! v x |> for(0..3)
    ! each _ |> _
    | done |> std/io:print.ln("done")

std/store:stored { c.v: 1 }
