// OPTIONAL EFFECT ARMS from subflow impls, omitted case — 400_131's generator
// with `! ?each`; the consumer handles ONLY `| done`. Ruled 2026-07-03: an
// unhandled optional VOID fire is a silent no-op (210_076: "unhandled calls
// become no-ops") that costs nothing. The no-op lives at the FIRE site — a
// comptime presence guard that folds the call away when the consumer omitted
// the handler — never as a synthesized stand-in in the consumer's handler
// struct, which would make presence (`if(each)`, 400_154) read "installed"
// for a handler nobody wrote. Value-resuming arms instead require an
// explicit presence test (400_146/149).
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
