// PINS `[layout(row)]`: the two grid layouts are OBSERVATIONALLY IDENTICAL.
//
// A grid's cells are stored one array per field (`column`, the default) or one
// record per cell (`row`). That choice is a pure codegen decision and this test
// is the thing that says so: the same writes, the same cross-cell read, and the
// same guarded sweep run over both, and the two totals must agree. If they ever
// diverge, the layout has become semantically visible and that is a bug in the
// lowering, not a tuning question.
//
// WHY THE CHOICE EXISTS. Column layout puts each field in its own array, which
// is what a dense sweep over ONE field wants and what lets it vectorise. Row
// layout packs a cell's fields together, which is what a SCATTER wants -- many
// fields of one cell at a computed index, touching one cache line instead of
// one per field.
//
// BOTH DIRECTIONS ARE MEASURED, and the sign flips hard:
//
//   scatter-dominated (003_ecs_reactive boids, 100k boids into a 32768-cell
//   grid, interleaved, checksum 592303452 both ways)
//       column 98.7ms   row 91.5ms      -- row wins by 7%
//
//   sweep-dominated (004_grid_layout, nine i64 fields, 1M cells, 400 sweeps
//   reading one field, same total both ways)
//       column 0.04s    row 0.45s       -- column wins by 11x
//
// That second number is why this is a declaration and not a default anyone
// gets to pick centrally, and it is checked in as a runnable pair rather than
// quoted here, so the losing direction cannot quietly rot while the winning
// one stays on the board.
//
// It is spelled as an annotation for the same reasons `[unsafe(bounds)]` is:
// it describes how the table is compiled rather than what it holds, the
// language already has a form for that, and it NAMES the choice so a typo is
// refused (697_011) instead of silently keeping the layout you meant to change.
//
// The store design already ruled this -- "layout is the closure of the queries"
// -- and this is the first rung of honouring it. The annotation lands before
// any inference so the choice is available and measurable, and it stays
// afterwards as the override.
//
// Both grids also carry a MULTI-FIELD cell and a cross-cell read
// (`g[6].a: g[2].a + 1`), because a single-field grid would not distinguish the
// two layouts at all and a same-cell read would not exercise the address form.
import std/io
import std/store
import std/grid

std/grid:new(colg, size: 8) { a: 0[i64], b: 0[i64] }
[layout(row)]std/grid:new(rowg, size: 8) { a: 0[i64], b: 0[i64] }
[layout(column)]std/grid:new(explicitg, size: 8) { a: 0[i64], b: 0[i64] }

std/store:new(acc) { n: 0[i64], m: 0[i64], e: 0[i64] }

std/grid:stored { colg[2].a: 5, colg[2].b: 7 }
std/grid:stored { rowg[2].a: 5, rowg[2].b: 7 }
std/grid:stored { explicitg[2].a: 5, explicitg[2].b: 7 }

std/grid:stored { colg[6].a: colg[2].a + 1 }
std/grid:stored { rowg[6].a: rowg[2].a + 1 }
std/grid:stored { explicitg[6].a: explicitg[2].a + 1 }

std/grid:sweep(colg)
! sweep c when c.a > 0 |> std/store:stored { acc.n: acc.n + c.a * 10 + c.b }

std/grid:sweep(rowg)
! sweep c when c.a > 0 |> std/store:stored { acc.m: acc.m + c.a * 10 + c.b }

std/grid:sweep(explicitg)
! sweep c when c.a > 0 |> std/store:stored { acc.e: acc.e + c.a * 10 + c.b }

std/io:print.ln("column {{ acc.n:d }} row {{ acc.m:d }} explicit {{ acc.e:d }}")
