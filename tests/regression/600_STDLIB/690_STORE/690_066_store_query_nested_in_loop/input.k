// MESSAGE-QUALITY PIN (RED until the diagnostic teaches the real constraint).
//
// std/store:query is a STANDING-RULE INSTALLATION (like watch): comptime-fused,
// its body copied into write sites. Ruled 2026-07-18 (concept:
// frag-store-verb-placement): installations are TOP-LEVEL-ONLY BY CONSTRUCTION
// — at runtime inside an effect/loop body there is nothing to install into, so
// in-body installation is incoherent by design, NOT a lowering bug. (Momentary
// verbs — insert/take — DO run in nested bodies; 690_037 pins that green. The
// discriminator that refuted the "registry-scan bug" hypothesis was exactly
// "insert-in-body works, query-in-body doesn't".)
//
// So this test does NOT expect rows. It expects a GOOD diagnostic. Today the
// compiler emits the MISLEADING "unknown store - no std/store:new(items) found"
// — but the store IS declared (capacity: 8). The real cause is "query is a
// standing-rule installation; install it at top level". This pin fails until
// the message stops lying (NOT_CONTAINS "unknown store") and teaches the
// constraint (CONTAINS "top-level"). Message quality IS the point (the frag's
// own open TODO). The on-demand row-sweep a retained-mode renderer needs is a
// SEPARATE capability (the plural stripe gap), not this.

import std/io
import std/store

std/store:new(items, capacity: 8) { v: i64 }
std/store:insert(items) { v: 10 }
std/store:insert(items) { v: 20 }

for(0..2)
! each _ |> std/store:rule(items)
    ! row e |> std/io:print.ln("v {{ e.v:d }}")
