// A store column read in a BRANCH-RESOLUTION PAYLOAD lowers to the cell, the
// same as the identical read in the subflow's GUARD one line above it.
//
//   pick = if(s.n > 0)      <- always threaded
//   | then => got s.n       <- used to reach Zig as a bare, undeclared `s`
//
// WHAT WAS ACTUALLY MISSING. Not a feature and not a decision about the
// language: `std/store:new` owns a whole-program walk that rewrites every
// `<store>.<field>` it can reach, and that walk enumerates the text positions
// an expression may stand in ONE BY ONE — a guard's `condition`, an
// invocation's args, an `Expression` arg's captured text, a template's frozen
// `inline_body`, an `inline_code` node, a produce arm's `.expression`, a
// bare-return subflow's BranchConstructor. The branch-constructor NODE was the
// one member of that list nobody had written down. Every position added to it
// so far arrived the same way: valid Koru, a raw identifier in the emitted Zig,
// and a diagnostic naming no Koru construct. `.expression` came in at 110_022;
// `inline_body` at 690_074; this one is 690_256.
//
// So the honest reading of this test is not "branch payloads now work" but
// "the enumeration is one entry longer". A walk that must be told each place an
// expression can appear will keep being short one place, and the next gap will
// look exactly like this one did.
//
// TWO WALKS, BOTH FIXED. store.kz carries a singleton copy of the walk and a
// plural copy, in different scopes, and only the singleton one is exercised
// here. 690_257 is the same program with a plural store declared first, which
// puts the plural walk in front and pins its copy of the rule — measured by
// disabling each arm in turn: with the singleton arm inert 690_257 still
// compiles, with only the plural arm 690_256 still fails.
//
// Found while porting celld's durability gate (830_THE_WORLD/842). That port
// does not need this shape — celld's own `await_durable(cell, epoch, position)`
// takes the position as an argument, so passing it as a tor input is the
// faithful spelling and it worked all along. This was pinned because the break
// was data, not because the port was blocked.
//
// Neighbour: 690_252 fixed the sibling case — a phantom-typed capture crossing
// into a `std/store:query` arm, where `lookupBranchIn` read the branch payload's
// type and left its `<state!>` behind. Same branch-payload position, a
// different thing dropped: there the obligation, here the store binding itself.
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
