// FRONTIER: a store column read in a BRANCH-RESOLUTION PAYLOAD is dropped at
// emission, while the identical read in the subflow's GUARD is threaded fine.
//
// The two reads below are the same expression, `s.n`, in one subflow:
//
//   pick = if(s.n > 0)      <- threaded correctly
//   | then => got s.n       <- emitted as a bare `s`, undeclared in Zig
//
// Replacing only the payload with a literal (`=> got 7`) compiles and prints 7,
// so the guard is not what breaks and the store is genuinely in scope for the
// subflow. What is dropped is specifically the capture for a value used to
// RESOLVE A BRANCH.
//
// Actual: output_emitted.zig ... error: use of undeclared identifier 's'
// Expected: prints 7 — or, if reading a store from a branch payload is meant to
// be refused, a Koru diagnostic saying so rather than a raw Zig identifier
// error leaking out of the backend.
//
// Found while porting celld's durability gate (830_THE_WORLD/842). That port
// does not need this shape — celld's own `await_durable(cell, epoch, position)`
// takes the position as an argument, so passing it as a tor input is the
// faithful spelling and it works. This is pinned because the break is data, not
// because the port is blocked.
//
// Neighbour: 690_252 fixed the sibling case — a phantom-typed capture crossing
// into a `std/store:query` arm, where `lookupBranchIn` read the branch payload's
// type and left its `<state!>` behind. Same collector, same branch-payload
// position, a different thing dropped: there the obligation, here the store
// binding itself.
import std/io
import std/store

std/store:new(s, capacity: 1) { n: 7[i64] }

pub tor pick {}
| got i64
| none

pick = if(s.n > 0)
| then => got s.n
| else => none

pick()
| got v |> std/io:print.ln("{{ v:d }}")
| none |> std/io:print.ln("none")
