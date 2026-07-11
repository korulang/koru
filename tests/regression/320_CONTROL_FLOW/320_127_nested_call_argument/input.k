// PIN (2026-07-05, Lars-ruled): a value-event call nested directly as a
// named argument to another call — r1(x: r1(x: 5)) — is ILLEGAL. The
// language idiom is bind-first:
//     r1(x: 5): a |> r1(x: a)
// and the corpus is uniformly written that way. Composition lives in the
// flow, where purity, obligations, and lifetimes are checkable — never
// inside expressions.
//
// Guarded by the KORU104 expression-admission wall (flow_checker, Stage A).
// Before the wall, this passed Stage A/B and the emitter pasted the inner
// call's Koru syntax verbatim into emitted Zig (raw Stage-D host error).
// Surfaced by the wordfreq kernel port (koru-benchmarks 19/22).
import std/io

pub event r1 { x: i64 } -> i64
r1 -> @rem(x * 16807, 2147483647)

r1(x: r1(x: 5)): v |> std/io:print.ln("{{ v:d }}")
