// PINS: one `stored` block in a sweep arm writes TWO columns of the swept row.
//
// Every `stored` site in the corpus writes exactly one column — 690_111 advances
// `b.x` alone across an all-f64 container, 695_001 chains single-field writes
// with `|>`. So the plural block is a shape the corpus has never asked for, and
// it is the literal shape of an ECS integration step: `pos += vel` is three
// fields under one arm.
//
// The pin covers the write reaching BOTH columns and the arm's row binding
// surviving the second field.
import std/io
import std/store

std/store:new(ents, capacity: 4) { px: i64, vx: i64, py: i64, vy: i64 }

std/store:insert(ents) { px: 0, vx: 1, py: 0, vy: 2 }
std/store:insert(ents) { px: 10, vx: 3, py: 20, vy: 4 }

std/store:sweep(ents)
! sweep e |> std/store:stored { e.px: e.px + e.vx, e.py: e.py + e.vy }

std/store:sweep(ents)
! sweep r |> std/io:print.ln("p {{ r.px:d }} {{ r.py:d }}")
