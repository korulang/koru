// OPTIONAL ARMS, presence in `when`-guard position — designed 2026-07-03.
// The presence expression is the SAME expression kind in both homes: an
// `if(...)` condition (400_146) and a `when` guard (this test). Here the
// generator's impl guards its `note(i)` fire on the consumer having
// installed the optional handler — `when note` reads "when someone is
// listening" — and skips evaluating the payload entirely when nobody is.
//
// RULED 2026-07-03: a presence guard counts as FULL coverage of the
// upstream branch, required or not — NO unguarded fallback sibling is
// needed. The 210_084/085 when-only rejection targets RUNTIME value guards,
// which drop an unpredictable subset of firings (a silent per-firing hole).
// A presence guard is COMPTIME: per consumer it is all-or-nothing,
// statically known, visible in source — and its false case ("nobody
// installed `note`") is exactly the trajectory the `?` on the arm already
// blesses. Forcing a fallback here would demand a branch whose entire
// content is the no-op the optional contract already implies.
//
// This consumer DOES install `note`, so every firing lands on the guard.
import std/io
import std/control

pub event gen { n: usize }
! ?note usize
| done usize

gen = for(0..n)
! each i when note |> note(i)
| done => done n

gen(n: 3)
! note i |> std/io:print.ln("note {{ i:d }}")
| done n |> std/io:print.ln("{{ n:d }}")
