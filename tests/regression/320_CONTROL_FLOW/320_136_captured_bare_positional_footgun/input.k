// PIN — bare expressions in `captured { }` are rejected (nothing is positional).
//
// A bare entry must PUN a field name/path, or be REJECTED ("name the target:
// `x: a.x + 1`"). Reordered bare expressions must not silently assign by index.
// This MUST_ERROR pins that `captured { a.y + 100, a.x + 1 }` is rejected with a
// teaching diagnostic naming the positional hazard.
import std/io
capture { x: 0[i64], y: 0[i64] }
! as a |> captured { a.y + 100, a.x + 1 }
| captured r |> std/io:print.ln("x={{ r.x:d }} y={{ r.y:d }}")
