// The grid is declared HERE and used from the entry file. Nothing in this
// module reads it — that is deliberate, so the only cell references in the
// program are the cross-module ones.
import std/grid

std/grid:new(cells, size: 8) { count: 0[i64] }

pub tor seed {}
seed = std/grid:stored { cells[2].count: 41 }
