// PINS: a store rebuilt row by row into a second store — a sweep arm whose
// body is an INSERT whose literal is fed by ROW PROJECTIONS (`id: s.id`),
// then the copy read back independently of its source.
//
// This is ecs_bench_suite's serialize round-trip (rust-gamedev's workload)
// at the store level: dump every row (the text half is the print sweep),
// reconstruct a corpus from dumped values (the rebuild sweep — exactly what a
// deserializer does per row). There is no whole-store save/load verb — the
// gauntlet-2 hole — so row-at-a-time is the only expressible round-trip; the
// corpus had momentary verbs in nested bodies (690_042) but never a row
// projection crossing into another store's insert literal.
import std/io
import std/store

std/store:new(src, capacity: 4) { id: i64, hp: i64 }
std/store:new(dst, capacity: 4) { id: i64, hp: i64 }

std/store:insert(src) { id: 1, hp: 10 }
std/store:insert(src) { id: 2, hp: 20 }

std/store:sweep(src)
! sweep r |> std/io:print.ln("row {{ r.id:d }} {{ r.hp:d }}")

std/store:sweep(src)
! sweep s |> std/store:insert(dst) { id: s.id, hp: s.hp }

std/store:sweep(dst)
! sweep d |> std/io:print.ln("copy {{ d.id:d }} {{ d.hp:d }}")
