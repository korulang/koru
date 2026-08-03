// PINS (RED, awaiting a ruling): a sweep body reaching the ENCLOSING TOR'S
// INPUT. `pos += vel * dt` is the shape — the single most common thing an ECS
// system does, and the reason this is not merely a curiosity.
//
// Measured 2026-08-03: `use of undeclared identifier 'dt'`, raw Zig, in
// generated code. Not a Koru diagnostic. Whatever the ruling below, THAT is a
// defect on its own: the refusal must name `dt` and the rule it broke.
//
// THE ASYMMETRY IS THE ARGUMENT. 690_073 is GREEN and captures a mid-chain
// BIND into the very same body position:
//
//     make(): n |> for(0..1)
//     ! each _ |> std/store:query(items)
//         ! query e |> ... n ...          <-- n is captured, works today
//
// An enclosing tor's INPUT is at least as enumerable as a mid-chain bind — it
// is declared in the signature — yet it does not reach the body at all. The
// capture machinery already exists and is already threaded: store.kz calls
// Cap.collectEventInputs, but only when the holding flow is a SYNTHESIZED
// `__store_sweepbody_` (a sweep nested in another sweep). A user-declared tor
// never takes that branch, so its inputs never enter the capture set.
//
// WHY IT IS NOT OBVIOUSLY A BUG — the ruling Lars owns. 690_STORE/DESIGN.md T1
// (transplant-purity) says a transplanted body's free names must be a subset of
// {its query-block bindings} u {comptime-known names: module decls, qualified
// calls, other stores}. An event input is NOT in that set, so today's refusal
// is T1 working as written. But 690_073 already admits mid-chain binds, which
// are not in that set either — they are threaded in as captures by value. So
// the question is not "does T1 forbid this" but "is an enclosing tor's input
// the same KIND of enumerable name as a mid-chain bind". If yes, T1's set
// widens by one member and the existing mechanism carries it.
//
// This pin is the evidence, not a proposal. It is deliberately red, the way
// 690_069 holds the row-ordinal requirement: the shape stays in the corpus so
// the requirement does not leave with it.
//
// SCOPE NOTE: this is NOT a module-boundary defect. The entry-file twin above
// is the whole test — no imports, one file — and it fails identically to the
// multi-module spelling. Module resolution reaches the store by bare name
// across files today (690_088, ruled and green).
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
