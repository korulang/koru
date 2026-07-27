// PINS: a chain that binds NOTHING cannot produce a value with `-> v`. `v`
// names nothing, and the refusal is KORU's, not the host's.
//
// The discriminator for a legal arrow is not "is this line a chain" — it is
// whether ANY bind stands between the start of the line and the arrow. Here a
// `|>` does stand before the arrow, and the arrow is still stray: no step binds
// anything, so `v` is a name the author reached for and never introduced.
//
// The shape this guards against is a leak, not a wrong answer. Admitted, it
// reaches the host as
//
//     output_emitted.zig:71:20: error: use of undeclared identifier 'v'
//                 return v;
//
// pointing into generated code at a line the author never wrote, in a file they
// never opened. Same family as 210_173 and 400_157: a host-language error
// standing in for a language one is a check that never fired.
//
// The third corner of the set. 210_182 is bind-on-a-later-step, which passes.
// 210_183 is no-chain-no-bind, which is refused. This is chain-but-no-bind, and
// it is refused for the same reason 210_183 is — the pipe was never what made
// the difference.
import std/io

tor seed {} -> i64
proc seed|zig { return 1; }

tor bump { subject: i64 } -> i64
proc bump|zig { return subject + 10; }

tor run {} -> i64
run = seed() |> bump() -> v

run(): r |> std/io:print.ln("run = {{ r:d }}")
