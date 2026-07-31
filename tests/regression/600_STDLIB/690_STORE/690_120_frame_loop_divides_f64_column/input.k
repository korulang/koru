// PINS: compute-shaped arithmetic through the sweep write path — an f64
// column written from a rhs with DIVISION and a PARENTHESIZED subexpression
// reading four sibling columns (a 2x2 determinant), then a second column
// halved across repeated frame passes (`for` wrapping a sweep, 690_067's
// nesting).
//
// This is ecs_bench_suite's heavy_compute (rust-gamedev's workload): a matrix
// inverted per row, per frame. The corpus's stored rhs before this was `+`/`-`
// only (690_111, 690_114); `/` and parens had never crossed the stored block.
// The FULL inverse — four writes under one arm — is the plural stored block,
// 690_118's pin; each element alone is a single-column write, this shape.
// a lands on d/det = 6/(24-14); b halves three times from 7.0.
import std/io
import std/store

std/store:new(mats, capacity: 4) { a: f64, b: f64, c: f64, d: f64 }

std/store:insert(mats) { a: 4.0, b: 7.0, c: 2.0, d: 6.0 }

std/store:sweep(mats)
! sweep m |> std/store:stored { m.a: m.d / (m.a * m.d - m.b * m.c) }

for(0..3)
! each _ |> std/store:sweep(mats)
    ! sweep n |> std/store:stored { n.b: n.b / 2.0 }

std/store:sweep(mats)
! sweep r |> std/io:print.ln("a {{ r.a:f }} b {{ r.b:f }} c {{ r.c:f }} d {{ r.d:f }}")
