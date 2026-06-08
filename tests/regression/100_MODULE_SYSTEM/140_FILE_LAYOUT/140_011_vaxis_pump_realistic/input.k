// Realistic vaxis-shaped event pump — three effect kinds dispatched on a
// deterministic mix, invocation handlers mutating per-host module state.
//
// The interleave mirrors `demos/sandbox/js_target_spike/dispatch_bench.mjs`
// (m = i % 64; resize every 64th, focus every 32nd-not-64th, key otherwise;
// key carries 'q' (113) every 97th event). That makes this fixture directly
// comparable to the hand-rolled JS dispatch strategies in the bench, with
// the same handler work and the same event-count signature.
//
// What this proves beyond 140_010: THREE kinds (not two), real work in each
// handler (counter + sum + xor + conditional quit-counter), so neither V8
// nor LLVM can DCE the dispatch to a tie.
pub event run { n: u64 }
! key u64
! resize u64
! focus-in u64

pub event onKey { ch: u64 }
pub event onResize { width: u64 }
pub event onFocus { id: u64 }
pub event report {}

run(n: 200)
! key c |> onKey(ch: c)
! resize w |> onResize(width: w)
! focus-in f |> onFocus(id: f)
report()
