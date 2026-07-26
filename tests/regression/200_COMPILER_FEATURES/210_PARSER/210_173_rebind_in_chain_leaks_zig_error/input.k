// PINS: re-binding a name already bound in the same chain is refused by KORU,
// with a koru sentence.
//
// Ruled by Lars 2026-07-27: rebinding is shadowing, and it should be illegal —
// and once a chain step's result threads by punning (210_172) it is also
// unnecessary, so there is no shape this spelling serves.
//
// It IS rejected today, but by Zig:
//
//     error: redeclaration of local constant 'n'
//
// pointing into `output_emitted.zig` at a name the author did write, in a file
// they did not. The wall is real and lives one layer too low; what is missing
// is a koru diagnostic naming the shadow and pointing at the second bind.
//
// Sibling of 510_109 in kind: a host-language error standing in for a language
// one is a check that never fired, not a check that is wrong.
import std/io

tor seed {} -> i64
proc seed|zig { return 1; }

tor bump { n: i64 } -> i64
proc bump|zig { return n + 10; }

seed(): n |> bump(n): n |> bump(n): n |> std/io:print.ln("rebound = {{ n:d }}")
