// PINS: the thread refuses to elect between two unfilled parameters that both
// accept its type — the ambiguity is NAMED, never guessed.
//
// `merge` declares two `i64` parameters and the chain writes neither, so both
// are unfilled and both accept the thread. That is the genuine ambiguity the
// type rule leaves open, and 210_176's rule answers it with a compile error
// naming the candidates rather than a silent pick.
//
// Writing one of them resolves it — written arguments narrow the field first,
// and the thread then fills whichever is left. That is why the diagnostic
// teaches the fix instead of forbidding the shape: `send-mail { to, subject,
// body }` is three parameters of one type and is perfectly threadable once two
// are written.
//
// The `several` half of "zero or several is a compile error naming them".
// Its `zero` twin is 210_181; the rule itself is 210_176.
import std/io

tor seed {} -> i64
proc seed|zig { return 7; }

tor merge { base: i64, incoming: i64 } -> i64
proc merge|zig { return base + incoming; }

seed() |> merge(): r |> std/io:print.ln("merged = {{ r:d }}")
