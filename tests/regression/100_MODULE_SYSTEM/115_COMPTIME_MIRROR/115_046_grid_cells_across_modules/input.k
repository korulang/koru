// MIRROR for the grid's CELLS, as distinct from its generated units: the grid
// is declared in `app/lib` and read, written and swept from the entry file.
//
// 115_045 is the units mirror and it was green while this was broken, because
// it declares AND uses the grid inside the same module. A cell reference lowers
// to `__koru_grid_<g>` / `__KoruGridT_<g>`, which are members of the module
// that declared the grid; emitted into any other module they are undeclared
// identifiers, and emitted as non-`pub` members they are invisible even when
// correctly named. Both halves were wrong and each looks complete alone.
//
// This is the FOURTH instance of one defect in this family — 115_018 for the
// store's paths, 115_044 for `[id]`'s cell reference, 115_045 for the grid's
// write and sweep units, and now the cells. The pattern is stable enough to
// state as a rule: ANY generated reference to a declaration's emitted member is
// unqualified until a cross-module test says otherwise, and the entry file can
// never be that test, because there the module's own name and `main_module`
// are the same namespace.
//
// The whole-program read pass made this urgent rather than theoretical: before
// it, a cell reference could only be emitted by `stored`/`sweep`, so the blast
// radius was two sites. Now a read can be emitted into any guard, argument or
// interpolation in the program.
//
// 41 + 1 = 42, and the sweep sees the same cell the write did.
import std/io
import std/store
import std/grid
import app/lib

std/store:new(acc) { n: 0[i64] }

app/lib:seed()

std/grid:stored { cells[2].count: cells[2].count + 1 }

if(cells[2].count == 42)
| then |> std/io:print.ln("cross-module read ok")
| else |> std/io:print.ln("BAD cross-module read")

std/grid:sweep(cells)
! sweep c when c.count > 0 |> std/store:stored { acc.n: acc.n + c.count }

std/io:print.ln("swept {{ acc.n:d }}")
