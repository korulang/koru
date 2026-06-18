// TEST: an UNCLOSED paren in a capture-write field value must be rejected LOUDLY
//       at the parser. Sibling of 100_081/082 (stray CLOSERS in call args), but a
//       different path: parseBranchConstructor's field-value handling. Here the
//       `@as(...` is never closed.
//
// MUST_FAIL: unbalanced
//
// Currently the imbalance is SWALLOWED — koruc exits 0, emits no diagnostic, and
// the malformed value produces an EMPTY program (no output) instead of a parse
// error. This cost real debugging time (a missing paren in an AoC conway
// expression read as a phantom "emission emits empty" bug). Reject it at the
// parser, located at the user's source.
import std/io

capture { x: 0[i64] }
! as a |> captured { x: a.x + @as(i64, @intFromBool((1 + 2) == 3) }
| captured r |> std/io:print.ln("{{ r.x:d }}")
