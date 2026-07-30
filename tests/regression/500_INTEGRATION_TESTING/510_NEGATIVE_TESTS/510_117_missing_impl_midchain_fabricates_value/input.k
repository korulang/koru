// PIN: the sharp end of 510_116. Bind the unimplemented event's result and print
// it. The compiler fabricates a zero-default and hands it downstream as if it
// were computed.
//
// Observed 2026-07-30:  ✓ Built executable  →  `clean=[]`
//
// The empty string is not an error state, an empty-state design, or a documented
// default. It is a substitute output standing in for a path that was never
// built — the exact thing the project's no-fallbacks rule bans, occurring inside
// the compiler, on behalf of the author, silently. A reader of that output cannot
// distinguish "the validator returned empty" from "there is no validator."
//
// Not string-specific. The same shape with `-> i64` was verified the same day:
//
//     tor bump { n: i64 } -> i64      (no implementation)
//     seed(): a |> bump(n: a): b |> print.ln("bump gave {{b:d}}")
//     →  bump gave 0
//
// So an arithmetic pipeline can silently lose a stage and report a plausible
// number. That is the worst reachable outcome of this hole and the reason it is
// pinned separately from 510_116 rather than as a second case inside it: 116
// pins that the wall does not fire, 117 pins what the program does instead.
//
// Kept as `string` here to stay minimal and to match the doodle's own types; the
// i64 variant is recorded above rather than as a fourth directory because it
// exercises the same single missing check.
import std/io

tor get-from-network {} -> string
get-from-network -> "Hello, World!"

tor validate-response { response: string } -> string

get-from-network(): r
|> validate-response(response: r): clean
|> std/io:print.ln("clean=[{{clean:s}}]")
