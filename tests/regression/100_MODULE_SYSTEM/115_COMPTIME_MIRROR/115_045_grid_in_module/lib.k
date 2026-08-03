import std/io
import std/store
import std/grid

std/grid:new(cells, size: 8) { count: 0[i64] }
std/store:new(acc) { n: 0[i64] }

pub tor bump {}
bump = std/grid:stored { cells[2].count: cells[2].count + 1 }

pub tor total {}
total = std/grid:sweep(cells)
! sweep c when c.count > 0 |> std/store:stored { acc.n: acc.n + c.count }

pub tor show {}
show = std/io:print.ln("total {{ acc.n:d }}")
