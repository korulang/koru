// PINS: a pairwise f64 pass over one store — the numeric consumer's shape,
// end to end. 690_111 pins the all-f64 container elementwise; 690_112 pins
// the nested same-store accumulate in i64. This is their meeting point: both
// row bindings read inside one f64 expression, the outer row written, N²
// including the self-pair.
//
// Each row accumulates its displacement to every row: sum over b of
// (b.x - a.x) = S - N*a.x. The self-pair contributes zero, so the totals
// separate the rows: with x = 0.5, 1, 2.25 (S = 3.75), acc lands on
// 2.25, 0.75, -3 — a shared cursor or a wrong-store read cannot produce
// all three.
import std/io
import std/store

std/store:new(pts, capacity: 8) { x: f64, acc: f64 }

std/store:insert(pts) { x: 0.5, acc: 0.0 }
std/store:insert(pts) { x: 1.0, acc: 0.0 }
std/store:insert(pts) { x: 2.25, acc: 0.0 }

std/store:sweep(pts)
! sweep a |> std/store:sweep(pts)
    ! sweep b |> std/store:stored { a.acc: a.acc + (b.x - a.x) }

std/store:sweep(pts)
! sweep r |> std/io:print.ln("x {{ r.x:f }} acc {{ r.acc:f }}")
