// FOOTGUN PIN (RED until fixed) — `captured`'s BARE-entry form is POSITIONAL,
// in a language that swore nothing is positional.
//
// A bare entry (an expression with no `field:` name) maps to the cell's
// declared field BY INDEX (koru_std/control.kz:277 — `cells[i].name`). So the
// SAME two expressions, reordered, silently land in DIFFERENT fields:
//
//   capture { x, y } ! as a |> captured { a.x + 1, a.y + 100 }  =>  x=1   y=100
//   capture { x, y } ! as a |> captured { a.y + 100, a.x + 1 }  =>  x=100 y=1   (SWAPPED!)
//
// No error either way. The path is LATENT — the whole corpus uses only the
// NAMED form `captured { x: expr }` — which is exactly why a silent positional
// misassignment could ship unnoticed.
//
// The law: a bare entry must PUN a field name, or be REJECTED ("name the target:
// `x: a.x + 1`"). Positional assignment is never allowed. This MUST_FAIL pins
// that the reversed-bare form should be REJECTED with a teaching diagnostic.
// Today it compiles (positional) and prints `x=100 y=1` — RED.
import std/io
capture { x: 0[i64], y: 0[i64] }
! as a |> captured { a.y + 100, a.x + 1 }
| captured r |> std/io:print.ln("x={{ r.x:d }} y={{ r.y:d }}")
