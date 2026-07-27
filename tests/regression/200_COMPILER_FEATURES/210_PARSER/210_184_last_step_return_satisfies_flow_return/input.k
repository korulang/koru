// PINS: the last step's `-> T` satisfies the flow's declared `-> T`. No
// terminus is written, because there is nothing left to say.
//
// A BRANCH terminus already vanishes this way. `koru_std/compiler.kz`'s
// `~analysis` ends at its last stage with only the dedented `| failed` choke —
// no `| ctx c5 => ctx c5` — because the final stage's `ctx` matches the flow's
// declared `| ctx` branch. The compiler self-hosts through that form.
//
// A BARE RETURN gets no such courtesy. `run = seed(): a |> bump(subject: a)`
// with `tor run {} -> i64` produces nothing, and says so in Zig — "function
// with non-void return type 'i64' implicitly returns" — not in Koru. So the
// author writes `bump(subject: a): v -> v`, naming a value for one line in
// order to hand it straight back.
//
// That is the same asymmetry the thread rule closed, in the same place: a
// branch has a name to match on and a bare return does not. The rule is the
// same too — match by TYPE. The last step returns an `i64`, the flow declares
// an `i64`, and no third thing is needed to connect them.
//
// Sibling of 210_176 (WHERE the thread lands mid-chain) and 210_182 (an arrow
// terminus that follows a chain). This one pins the terminus that is not
// written at all — and it is what `~frontend` wants, since the `: c4 -> c4` it
// still carries is the last binder in the pass.
import std/io

tor seed {} -> i64
proc seed|zig { return 1; }

tor bump { subject: i64 } -> i64
proc bump|zig { return subject + 10; }

tor run {} -> i64
run = seed(): a |> bump(subject: a)

run(): r |> std/io:print.ln("run = {{ r:d }}")
