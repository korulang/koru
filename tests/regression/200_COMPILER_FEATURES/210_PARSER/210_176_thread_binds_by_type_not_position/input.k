// PINS: the point-free thread binds to the one UNFILLED parameter whose type
// it matches — not to a name, not to a position.
//
// Written arguments narrow the field first, then the type decides. Here `tag`
// is written, so only `n` is unfilled; the thread is an `i64` and `n` is the
// `i64`, so it lands there. `n` is declared SECOND, which is what makes this a
// pin about types rather than about order.
//
// The rule this guards, in full:
//
//     the thread fills the unfilled parameter whose type it matches.
//     exactly one candidate -> bind. zero or several -> compile error naming them.
//
// Three properties follow, and each is why a competing rule was rejected:
//
//   - ORDER-FREE. Reordering a tor's parameters changes nothing, anywhere.
//     Binding the thread to the first parameter would have made declaration
//     order load-bearing for the first time in the language — 110_025 is the
//     standing wall against exactly that, for the implicit expression slot.
//
//   - NO MAGIC NAME. No reserved `subject`/`self`/`this` slot, so a tor is free
//     to name a parameter anything a domain wants. `pcre2:find.all` already
//     declares `subject` for the string being matched, which a reserved name
//     would have collided with.
//
//   - PARTIAL FILL FALLS OUT. A tor whose parameters ALL share the thread's
//     type is still unambiguous once enough of them are written. Writing more
//     narrows; writing none of several same-typed parameters is the genuine
//     ambiguity, and that is the error case.
//
// This is 110_025's rule with one condition removed. That test pins the
// implicit expression slot as selected by "the parameter's TYPE and NAME";
// the thread has no name to offer, so it is selected by type alone.
//
// Sibling of 210_175 (a bare return threads) and 210_172 (a step's result
// moves forward at all). Those two pin THAT the value travels; this one pins
// WHERE it lands.
import std/io

tor seed {} -> i64
proc seed|zig { return 7; }

tor tally { tag: string, n: i64 } -> i64
proc tally|zig { return n + @as(i64, @intCast(tag.len)); }

seed() |> tally(tag: "abc"): r |> std/io:print.ln("tally = {{ r:d }}")
