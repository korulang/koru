// PIN (2026-07-03): the COMPOSITION of the two session emitter fixes — mutual
// tail-recursion flattening (emitter/mutual-tail-flatten) AND simultaneous
// (snapshot) reentry-arg assignment (emitter/tail-loop-parallel-assign). Neither
// branch handled this alone: ping/pong are a mutual-tail cycle (needs the
// combined dispatch loop) whose reargs cross-reference (a: b, b: a — needs the
// staged/simultaneous assignment, shared via emitTailReargs). Two mutual swaps of
// (1,2) return `a` to 1; a sequential rearg would corrupt the swap and yield 2.
import std/io

pub event ping { a: i64, b: i64, n: i64 } -> i64

pub event pong { a: i64, b: i64, n: i64 } -> i64

ping = if(n == 0)
| then -> a
| else |> pong(a: b, b: a, n: n - 1)
    | value v -> v

pong = if(n == 0)
| then -> b
| else |> ping(a: b, b: a, n: n - 1)
    | value v -> v

ping(a: 1, b: 2, n: 2): r |> std/io:print.ln("{{ r:d }}")
