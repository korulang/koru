// OPTIONAL EFFECT ARMS from subflow impls, omitted case — 400_131's generator
// with `! ?each`; the consumer handles ONLY `| done`. Ruled 2026-07-03: the
// no-op contract STAYS for void arms — an unhandled optional fire lowers to a
// synthesized no-op in the consumer's comptime handler struct (210_076:
// "unhandled calls become no-ops"), which monomorphizes away to nothing.
// Void arms are the one case where a no-op is an honest implementation;
// value-resuming arms instead require a presence test (400_146/149).
import std/io
import std/control

pub event gen { n: usize }
! ?each usize
| done usize

gen = for(0..n)
! each i |> each(i)
| done => done n

gen(n: 3)
| done n |> std/io:print.ln("{{ n:d }}")
