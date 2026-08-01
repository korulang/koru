// PIN (documented gap, red on purpose): a tor's OWN parameter is not
// captured into its impl flow's sweep-arm handler — the sweep arm's body
// is emitted as a handler fn whose Input captures the row fields
// (__koru_srf_*) but not the enclosing tor's params, so `d` below reaches
// Zig as an undeclared identifier.
//
// The contrast: a BRANCH binding threads fine — downloads.k's pump uses
// `pr.index` inside a nested sweep arm's when-guard, and kopium's
// handle-delta appends a branch-bound `t` inside a sweep arm. Only the
// tor-parameter route is missing, which forces any "helper tor that
// writes a store" (kopium's absorb) to be inlined at its call sites.
//
// When param capture lands, this flips to MUST_RUN with expected "7 5".

import std/io
import std/store

std/store:new(box, capacity: 4) { n: i64 }

std/store:insert(box) { n: 7 }
| row _ |> _
| full |> _

tor shout { d: i64 }
shout = std/store:query(box)
! query r |> std/io:print.ln("{{ r.n:d }} {{ d:d }}")

shout(d: 5)
