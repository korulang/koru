// PINS: component add/remove expressed as a PRESENCE-COLUMN write — set the
// bit on every row, observe membership through a guarded sweep, clear it,
// observe the guarded sweep now match nothing, and the rows survive intact.
//
// This is ecs_bench_suite's add_remove_component (rust-gamedev's workload).
// In an archetype engine adding a component MIGRATES the row between tables;
// under O13's no-archetypes ruling it is an ordinary column write firing
// ordinary deltas, and this pin is that claim as a program: the whole
// workload is two `stored` writes and two `when` guards (the guard gating
// 690_084 pins), with no row ever moving.
import std/io
import std/store

std/store:new(ents, capacity: 8) { hp: i64, frozen: i64 }

std/store:insert(ents) { hp: 10, frozen: 0 }
std/store:insert(ents) { hp: 20, frozen: 0 }

std/store:query(ents)
! query a |> std/store:stored { a.frozen: 1 }

std/store:query(ents)
! query b when b.frozen == 1 |> std/io:print.ln("frozen {{ b.hp:d }}")

std/store:query(ents)
! query c |> std/store:stored { c.frozen: 0 }

std/store:query(ents)
! query d when d.frozen == 1 |> std/io:print.ln("still frozen {{ d.hp:d }}")

std/store:query(ents)
! query e |> std/io:print.ln("alive {{ e.hp:d }}")
