// TEST: record-literal field labels inside an inlined subflow body are
// name positions, never call-site argument text.
//
// `f -> { x: x + 1, y: x }` is inlined at `f(r.x)` — the param `x` maps to
// the caller's `r.x`, and the produce expression's VALUE occurrences take
// the substitution (`x + 1` → `r.x + 1`). But the field LABEL `x:` names
// the produced record's field — a name position in the subflow's own
// scope. The textual substitution used to rewrite it too, handing
// `{ r.x: r.x + 1, y: r.x }` to the struct-literal lowerer, which read
// `r.x:` as a pun and emitted `.@"x + 1" = r.x: r.x + 1` — dead at the
// zig stage (`expected '}', found ':'`).
//
// Sibling of 230_023 (member names are not references) and 230_031
// (record literals in arg position): the same name-position law at the
// immediate-impl inline boundary.

import std/io

tor f { x: i64 } -> { x: i64, y: i64 }
f -> { x: x + 1, y: x }

tor box {}
| b { x: i64, y: i64 }
| none

box => b { x: 1, y: 0 }

box()
| b r |> f(r.x): v |> std/io:print.ln("{{ v.x:d }} {{ v.y:d }}")
| none |> _
