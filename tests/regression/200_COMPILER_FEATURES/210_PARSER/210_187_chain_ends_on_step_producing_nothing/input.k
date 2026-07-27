// PINS: a flow declaring `-> T` whose chain ends on a step producing NOTHING
// is refused, and the refusal is KORU's.
//
// This is the shape the synthesized terminus (210_184) must not paper over.
// `note` returns nothing, so there is no value for `run` to hand back, and the
// old symptom was the host's: "function with non-void return type 'i64'
// implicitly returns", pointing into generated Zig. Reading the last step's
// type is what makes the terminus vanish; reading it is also what makes this
// visible, and both have to come from the same rule or the rule is a guess.
//
// Twin of 210_186 (a chain ending on the wrong type). Same family as 210_181
// and 400_157: a host-language error standing in for a language one.
import std/io

tor seed {} -> i64
proc seed|zig { return 1; }

tor note { subject: i64 }
proc note|zig { _ = subject; }

tor run {} -> i64
run = seed(): a |> note(subject: a)

run(): r |> std/io:print.ln("run = {{ r:d }}")
