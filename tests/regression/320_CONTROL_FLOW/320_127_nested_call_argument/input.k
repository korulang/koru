// PIN (2026-07-05, honest red): a value-event call nested directly as a
// named argument to another call — r1(x: r1(x: 5)) — passes Stage A/B but
// the emitter pastes the INNER CALL'S KORU SYNTAX VERBATIM into the emitted
// Zig, which dies at Stage D with a raw host error:
//     output_emitted.zig: error: expected ')', found ':'
// Two defects in one: the mis-lowering, and the Zig-leak diagnostic (the
// koru-level wall "nested calls in argument position aren't lowered — bind
// the inner result first" doesn't exist).
//
// The corpus-wide idiom binds intermediates (`r1(x: 5): a |> r1(x: a)`),
// which is why no test ever hit this. Surfaced by the wordfreq kernel port.
//
// Correct behavior: compiles and prints r1(r1(5)) = r1(84035) = 1412376245.
import std/io

pub event r1 { x: i64 } -> i64
r1 -> @rem(x * 16807, 2147483647)

r1(x: r1(x: 5)): v |> std/io:print.ln("{{ v:d }}")
