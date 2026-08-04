// ASPIRATIONAL — RED ON PURPOSE. This is a GAP, not a rule.
//
// An indexed store read lowers in a write block (690_245), and inside a WRITE'S
// ROW ADDRESS (690_249, 690_253). It does NOT lower in a CALL ARGUMENT: the text
// `rows[ix[0].h].v` reaches the host verbatim and the backend refuses with
// `use of undeclared identifier 'rows'`.
//
// This is a REACH gap in the rewriter, not a decision about the language. Do not
// convert it to MUST_ERROR — that would record a limitation as a wall, which is
// the inverted-closed failure the corpus already names. When the lowering is
// widened to argument position, this test goes green as written.
//
// Third position known to lack the rewriter, after write-adjacent positions and
// `print.ln` (which does not run indexed-read lowering at all, so
// `{{ rows[h].v:d }}` also reaches the host verbatim).
//
// Found porting `fanout` in tests/benchmarks/003_ecs_reactive: the baseline folds
// its observer loop over the post-decrement value, and passing that value to the
// observer tor is exactly this shape. The port works around it by parking the
// value in a column first.
import std/io
import std/store
import std/grid

std/store:new(rows, capacity: 4) { v: i64 }
std/grid:new(ix, size: 4) { h: 0[i64] }

tor show { value: i64 }
show = std/io:print.ln("v {{ value:d }}")

for(0..2)
! each i |> std/store:insert(rows) { v: 10 + @as(i64, @intCast(i)) }
    | row t |> std/grid:stored { ix[i].h: t }
    | full |> _

show(value: rows[ix[1].h].v)
