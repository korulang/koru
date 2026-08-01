// ASPIRATIONAL (RED until the momentary sweep verb lands) — the store-side of
// the vaxis RENDER BRIDGE. See concept: frag-store-verb-placement.
//
// `std/store:sweep` is the MOMENTARY twin of `std/store:query` (named `sweep`
// not `each` because `! each` is already the for-loop's effect arm, KORU040):
//   - query  = a STANDING-RULE installation (comptime-fused into write paths,
//              fires on insert/write). Top-level-only BY CONSTRUCTION.
//   - sweep  = a MOMENTARY read of the corpus: "for each live row RIGHT NOW,
//              project fields, run the body." A runtime act on an existing
//              corpus, so — like insert/take — it is legal ANYWHERE a body runs,
//              INCLUDING a nested handler/loop body. This is what a retained-mode
//              renderer needs: vaxis `! draw` (fires on mount + every resize with
//              no store write) must read ALL live rows to repaint.
//
// The lowering MUST be SITE-LOCAL (the sweep loop emitted inline at the call
// site, the insert/take path — which composes in nested position), NEVER via the
// top-level coordinator (the query/__store_qsweep path — which does not). If it
// ever regresses to coordinator-shape, THIS nested site won't resolve and this
// test goes red — the tripwire.
//
// EXPECTED: 2 loop iterations, each sweeps both live rows on demand.

import std/io
import std/store

std/store:new(items, capacity: 8) { v: i64 }
std/store:insert(items) { v: 10 }
std/store:insert(items) { v: 20 }

for(0..2)
! each _ |> std/store:query(items)
    ! query e |> std/io:print.ln("v {{ e.v:d }}")
