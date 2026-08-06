// An indexed store read lowers in a CALL ARGUMENT: `show(value: rows[ix[1].h].v)`
// passes the column value, two hops deep, to an ordinary tor.
//
// This was the third position known to lack the rewriter, after the
// write-adjacent ones (690_245, 690_249, 690_253) and `print.ln` interpolation
// (690_250). All three were one absence: `indexedFieldRefs` lived inside the
// `stored` transform's private helper struct, and the whole-program walk that
// `std/store:new` runs could not see it. The rewriter is now file scope and
// both walks call it, so the reach question is settled for every text slot the
// walk visits rather than one position at a time.
//
// The header this file carried while it was red said "when the lowering is
// widened to argument position, this test goes green as written" — and it did,
// with no change to the program below. That is the strongest evidence the pin
// was recording a REACH gap and not a language decision, which is what its
// original author refused to convert to a MUST_ERROR. Keeping an aspirational
// test honest costs one red row on the board and buys exactly this.
//
// Found porting `fanout` in tests/benchmarks/003_ecs_reactive: the baseline
// folds its observer loop over the post-decrement value, and passing that value
// to the observer tor is exactly this shape. That port parks the value in a
// column to work around it; the workaround is now unnecessary.
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
