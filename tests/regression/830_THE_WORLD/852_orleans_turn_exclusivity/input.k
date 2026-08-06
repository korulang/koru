// The World in Koru — entry 10.
// Doorway: Orleans' turn model and `[Reentrant]`. (github.com/dotnet/orleans.)
//
// An Orleans grain is single-threaded per activation: `WorkItemGroup.Execute`
// carries the comment "This method is always called in a single-threaded
// environment" (Scheduler/WorkItemGroup.cs:140). One turn runs at a time. A
// turn that awaits SUSPENDS, and whether another turn may start while it is
// suspended is decided by `MayInvokeRequest` (Catalog/ActivationData.cs:1187) —
// the one genuinely pure predicate in that runtime, with no I/O and no timers,
// driven by the `[Reentrant]`, `[AlwaysInterleave]` and `[MayInterleave]`
// markers.
//
// WHY THIS DOORWAY AND NOT THE OBVIOUS ONE. Orleans is the ancestor of the
// Durable Objects model that entry 8 ported, so the tempting port is its
// single-activation guarantee. That port would be a lie. Orleans' exclusivity
// is BEST-EFFORT and its own source says so: the directory handoff path records
// "the applications which lost the registration race (duplicate activations)"
// and then destroys them (GrainDirectory/GrainDirectoryHandoffManager.cs:162,
// 174), and a wrongly-declared-dead silo lets a second activation replace a
// live one (GrainDirectoryPartition.Interface.cs:170). A compile-time guarantee
// on top of a best-effort runtime property is a lie with a checkmark on it.
//
// Reentrancy is different: it is within-silo, within-activation, and decided by
// a pure predicate. That is a scope a type system actually reaches.
//
// THE SAFE SHAPE. A turn is exclusive access to grain state. `state.bump` is
// read-modify-write ATOMIC WITHIN THE TURN — no value escapes, so no value can
// go stale, and an interleave between two bumps is harmless. That is precisely
// the advice every Orleans guide gives about reentrant grains, and here it is
// the shape the type system pushes you into rather than a rule to remember.
//
// LANGUAGE CORNER: borrow-versus-consume as the spelling of "does this
// suspension keep the turn?" A non-reentrant call BORROWS `<exclusive>`. A
// reentrant one CONSUMES it. Nothing in the names says which; the angle
// brackets do — and `[Reentrant]` in Orleans is a class attribute whose
// consequences are entirely on the developer to remember.
//
// The boundary is 855, and it is worth reading before believing this entry.
import std/io
import std/store

// One grain's state. Orleans grains are in-memory; there is no durability
// question here, which is why none of entry 8's gate machinery appears.
std/store:new(grain, capacity: 1) { count: 0[i64] }

// A TURN. Orleans runs one turn at a time per activation — `WorkItemGroup`'s
// run queue is drained by a single thread. The turn is exclusive access to
// grain state, and it is exclusive only while the turn is not suspended.
pub tor turn.begin { id: string } -> string<exclusive!>
turn.begin -> id

pub tor turn.end { turn: string<!exclusive> }
turn.end = std/io:print.ln("  turn {{ turn:s }} ends")

// Read-modify-write, ATOMIC WITHIN THE TURN. No value escapes, so no value can
// go stale. This is the shape the type system pushes you toward, and it is also
// the advice every Orleans guide gives about reentrant grains.
pub tor state.bump { turn: string<exclusive> }
state.bump = std/store:stored { grain.count: grain.count + 1 }
    |> std/io:print.ln("  bump -> {{ grain.count:d }}")

// A NON-REENTRANT call. Orleans holds the activation's turn across the await,
// so no other turn may start: exclusivity is BORROWED and survives.
pub tor call.blocking { turn: string<exclusive>, target: string }
call.blocking = std/io:print.ln("  await {{ target:s }} — non-reentrant, turn held")

// A REENTRANT await. `[Reentrant]` lets another turn run while this one is
// suspended, so exclusivity is CONSUMED and a fresh turn is handed back. The
// competing turn's work happens right here, which is exactly what interleaving
// means.
pub tor call.interleaving { turn: string<!exclusive>, target: string } -> string<exclusive!>
call.interleaving = std/store:stored { grain.count: grain.count + 1 }
    |> std/io:print.ln("  await {{ target:s }} — REENTRANT; another turn bumped to {{ grain.count:d }}")
    |> turn.begin(id: "resumed")

// Two bumps around a non-reentrant call: the turn is held throughout.
turn.begin(id: "t1"): t1
    |> state.bump(turn: t1)
    |> call.blocking(turn: t1, target: "other-grain")
    |> state.bump(turn: t1)
    |> turn.end(turn: t1)

// And around a reentrant one: exclusivity is surrendered and re-granted, and
// because nothing is held across the suspension, nothing is lost.
turn.begin(id: "t2"): t2
    |> state.bump(turn: t2)
    |> call.interleaving(turn: t2, target: "other-grain"): t3
    |> state.bump(turn: t3)
    |> turn.end(turn: t3)
