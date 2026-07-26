// PINS: a chain step's result threads to the next step by punning, so a
// pipeline that reads as threading a value actually threads it.
//
// Ruled by Lars 2026-07-27, writing a batch-building pipeline:
//
//     multi.new(): m |> multi.add(m, url: …) |> multi.add(m, url: …)
//
// Each `multi.add` takes `m` and returns the batch. Reading that, `m` is the
// batch as it moves down the chain — there is nothing else it could mean, and
// spelling a fresh bind at every step to say so is noise the language should
// not require.
//
// Today the binding does not move. `n` stays whatever the head bound, every
// intermediate result is discarded, and the program compiles and runs — which
// is the part that makes this worth a pin rather than a feature request. A
// pipeline that silently ignores its own steps is indistinguishable from one
// that works, until the numbers are wrong.
//
// `bump` adds 10, so a threading chain prints 21 and a non-threading one
// prints 1. The expected output is the ruling.
import std/io

tor seed {} -> i64
proc seed|zig { return 1; }

tor bump { n: i64 } -> i64
proc bump|zig { return n + 10; }

seed(): n |> bump(n) |> bump(n) |> std/io:print.ln("threaded = {{ n:d }}")
