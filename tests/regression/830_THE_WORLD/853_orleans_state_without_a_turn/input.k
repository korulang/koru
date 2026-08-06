// The World in Koru — entry 10, negative twin one of 852.
// Doorway: touching grain state from outside a turn. In Orleans this is
// structurally impossible for ordinary code — the scheduler hands you the
// activation only inside a turn — but it is impossible by CONSTRUCTION of the
// runtime, not by anything a compiler checks. Reach the object another way (a
// captured `this`, a background `Task.Run`, a timer callback that closes over
// the grain) and nothing stops you; that is the standard way people corrupt an
// Orleans grain.
//
// Here the state events require a turn that only `turn.begin` mints, so there
// is no spelling of "touch the state without a turn" that type-checks.
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

state.bump(turn: "made-up")
