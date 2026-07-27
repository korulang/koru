// PINS: a `|>` step that cannot take the thread is refused in KORU, naming the
// parameter it does have and the type that parameter is.
//
// `shout` is still incomplete — `text` is unfilled — and the thread arriving is
// an i64, so there is no home for it. The old shape of this failure was the
// host's: `missing struct field: text`, pointing into generated Zig at a name
// the author never wrote in a file they never opened. A wall that fires one
// layer too low is a check that never fired.
//
// The `zero` half of "zero or several is a compile error naming them". Its
// `several` twin is 210_180; the rule itself is 210_176. Same family as
// 210_173 and 400_157: a host-language error standing in for a language one.
import std/io

tor seed {} -> i64
proc seed|zig { return 7; }

tor shout { text: string } -> string
proc shout|zig { return text; }

seed() |> shout(): r |> std/io:print.ln("shouted = {{ r:s }}")
