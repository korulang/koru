// 011 — the LINQ post's headline task, on cs: filter -> map -> sum over
// 1..n. `when` on `! each` is the Where, `* 3` the Select, the `captured`
// write the Sum. The claim under test: generated cs for this shape vs LINQ
// and a handwritten foreach on the same runtime.
//
// The accumulator is a REAL `capture` cell — not a module static. Lowering
// `capture` on cs (a ValueTuple preamble) removed the shim; `acc` is now
// only the result boundary — it copies the finished cell's total out for
// the harness to read.
import std/io

pub tor acc { v: i64 }

pub tor run { n: i64 }

run = capture { total: 0[i64] }
! as g |> for(1..(@as(usize, @intCast(n)) + 1))
    ! each i when i % 2 == 0 |> captured { total: g.total + @as(i64, @intCast(i)) * 3 }
| captured res |> acc(v: res.total)

run(n: 10) |> std/io:print.ln("total={{ total:d }}")
