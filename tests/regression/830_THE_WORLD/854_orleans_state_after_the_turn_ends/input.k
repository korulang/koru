// The World in Koru — entry 10, negative twin two of 852.
// Doorway: using a grain after its turn is over. Orleans' deactivation path
// cancels pending operations and reroutes queued messages
// (Catalog/ActivationData.cs:596-666, 1136-1184), but an already-captured
// reference to the activation is just an object reference; nothing in the type
// of it expires when the turn does.
//
// Here the turn IS the permission, and ending it consumes the permission.
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

turn.begin(id: "t1"): t1 |> turn.end(turn: t1) |> state.bump(turn: t1)
