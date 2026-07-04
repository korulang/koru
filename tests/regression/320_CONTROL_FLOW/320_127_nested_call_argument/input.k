// PIN (2026-07-05, honest red — RULED by Lars this session): a value-event
// call nested directly as a named argument to another call —
// r1(x: r1(x: 5)) — is ILLEGAL. The language idiom is bind-first:
//     r1(x: 5): a |> r1(x: a)
// and the corpus is uniformly written that way.
//
// Today the compiler ACCEPTS this at Stage A/B and then pastes the inner
// call's KORU SYNTAX VERBATIM into the emitted Zig, dying at Stage D with a
// raw host error (output_emitted.zig: expected ')', found ':'). That is the
// defect this pin holds red: the koru-level wall doesn't exist, and a Zig
// leak stands where the diagnostic should be.
//
// Goes green when the compiler rejects this at the koru level with a
// diagnostic that names the construct and hints bind-the-inner-result-first.
// Surfaced by the wordfreq kernel port (koru-benchmarks 19/22).
import std/io

pub event r1 { x: i64 } -> i64
r1 -> @rem(x * 16807, 2147483647)

r1(x: r1(x: 5)): v |> std/io:print.ln("{{ v:d }}")
