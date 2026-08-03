import std/io
import std/grid

std/grid:new(cells, size: 8) { count: 0[i64] }

pub tor bump {}
bump = std/grid:stored { cells[2].count: cells[2].count + 1 }

pub tor overflow {}
overflow = std/grid:stored { cells[9].count: 1 }
