// The World in Koru — entry 10, THE BOUNDARY. This test passes, and a bump
// vanishes while it does.
//
// Doorway: the reentrancy lost update — the best-known way to hurt yourself
// with Orleans' `[Reentrant]`.
//
//     [Reentrant] class Counter : Grain {
//         int count;
//         public async Task Bump() {
//             var x = count;          // read
//             await other.Ping();     // another Bump may run HERE
//             count = x + 1;          // x is stale -> lost update
//         }
//     }
//
// The flow below is that program. `state.read` hands a value out of the turn,
// `call.interleaving` surrenders exclusivity and another turn bumps the count
// to 1, and then the write stores the value read BEFORE the suspension. The
// other turn's increment is gone and the count is back to 0.
//
// WHAT THE TYPE SYSTEM DOES CATCH, and it is not nothing: the written value
// cannot be forged (only `state.read` mints `<fresh!>`), a read cannot be
// silently dropped (an unwritten `<fresh!>` is refused), and neither read nor
// write can happen without a live turn (853, 854).
//
// WHAT IT DOES NOT CATCH: that `x` went stale. `<fresh>` is a statement about
// the binding `x`; `<exclusive>` is a statement about the binding `t1`; and
// Koru cannot say that the first dies when the second is discharged. Phantom
// states are per-binding, and this needs a dependency BETWEEN two bindings.
// Discharging `t1` at the interleave leaves `x` untouched and perfectly valid.
//
// A TRAP WORTH RECORDING, because the first draft of this test fell into it.
// Writing the natural `state.write(turn: t2, v: x + 1)` IS refused — and the
// refusal has nothing to do with staleness. Arithmetic strips the obligation,
// so `x + 1` carries no `<fresh!>` and is rejected identically in a flow with
// no interleave in it at all. Shipping that version would have published an
// incidental type error as a safety property. The bare `x` below is the honest
// case, and it compiles.
//
// That trap is also the second finding: this encoding can only express "write
// back exactly what you read." You cannot compute on a phantom-carrying value
// and keep the obligation — which is precisely why 852's atomic `state.bump`,
// where no value ever escapes the turn, is the shape that works.
//
// So entry 10's honest reading: obligations make the interleave point explicit
// and checked, and make the dangerous SHAPE avoidable. They do not make the
// dangerous shape detectable. Write the read-await-write and the compiler
// watches you do it.
//
// Pinned MUST_RUN because there is no diagnostic to pin — the absence is the
// result. Its sibling is 851, where linearity counted tokens and could not
// count identities.
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

// A read that hands a value OUT of the turn, and a write that consumes it.
pub tor state.read { turn: string<exclusive> } -> i64<fresh!>
state.read -> grain.count

pub tor state.write { turn: string<exclusive>, v: i64<!fresh> }
state.write = std/store:stored { grain.count: v }
    |> std/io:print.ln("  count := {{ v:d }}")

turn.begin(id: "t1"): t1
    |> state.read(turn: t1): x
    |> call.interleaving(turn: t1, target: "other-grain"): t2
    |> state.write(turn: t2, v: x)
    |> turn.end(turn: t2)
    |> std/io:print.ln("the other turn's bump is gone; count is {{ grain.count:d }}")
