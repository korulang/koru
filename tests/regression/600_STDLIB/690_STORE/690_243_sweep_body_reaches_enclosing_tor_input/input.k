// The ECS spelling of param capture: `pos += vel * dt` across several rows.
//
// 690_234 is the CANONICAL pin for this gap — it recorded it first, named the
// branch-binding contrast that proved it mechanical, and carried its own flip
// instruction. This test is the consumer layout of the same shape: two rows,
// real arithmetic, a system tor taking `dt`. Kept deliberately alongside the
// minimal spelling, because the green region around a behaviour is exactly as
// wide as the test that pins it — a moved line break or a second row is a
// different program to the compiler and the same program to its author.
//
// WHAT WAS ACTUALLY WRONG. Not a scope rule and not a design boundary. A tor's
// parameter materializes as `const dt = __koru_event_input.dt;` in the very
// frame that calls the sweeprun, one line above the call. The capture collector
// gathered mid-pipe binds, and gathered event INPUTS only when the host flow
// was a synthesized `__store_sweepbody_` (the nested-sweep case), so a user tor
// never took that branch. Everything else already worked: a sweep arm inside a
// tor body captures a mid-chain bind today, through the same two hops.
//
// The measurement that settled it: the SAME `dt`, the SAME body, reached the
// arm when it arrived as `tick(): dt |> query …` and did not when declared as
// a parameter. One origin, not one scope.
//
// NOT T1. T1 is transplant-purity for a WATCH body — spliced into the store's
// write path and executed wherever a write happens, so it cannot close over its
// declaring scope. A sweep body runs at the sweep site in the caller's frame.
import std/io
import std/store

std/store:new(bodies, capacity: 8) { px: 0[i64], vx: 0[i64] }

std/store:insert(bodies) { px: 0, vx: 1 }
std/store:insert(bodies) { px: 10, vx: 3 }

pub tor integrate { dt: i64 }
integrate = std/store:query(bodies)
! query e |> std/store:stored { e.px: e.px + e.vx * dt }

integrate(dt: 2)

std/store:query(bodies)
! query e |> std/io:print.ln("px {{ e.px:d }}")
