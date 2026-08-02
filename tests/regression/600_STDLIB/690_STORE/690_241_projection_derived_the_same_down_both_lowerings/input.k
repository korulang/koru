// THE DIFFERENTIAL PIN — one body, two lowerings, one answer.
//
// `rule` and `query` are two independent lowerings of the same idea: stand on
// a row, read it through a binding, write through `stored`. They have drifted
// before, and green tests could not see it, because no test compared the two
// paths TO EACH OTHER — each was green against its own expectation while the
// rule path kept a `while` the query path had already retired
// (frag-a-fix-lands-in-one-lowering-path).
//
// This pins the thing that drifted most recently: WHICH COLUMNS A SITE
// PROJECTS. Both paths now derive it from the body — every column the arm
// named, in declaration order — instead of one deriving and the other
// projecting the whole row.
//
// The store carries four columns and each arm names exactly two of them:
// `k` in the guard, `a` in the body. `b` and `c` are never named by either
// arm, so neither lowering may project them. If either path stops deriving
// (projects everything) or starts under-deriving (drops a named column), the
// emitted Zig either grows a dead load or fails as an unknown identifier —
// and the two totals below stop agreeing with the constant.
//
// Rows: k=1 rows contribute their `a`; the k=2 row must be skipped by both
// guards. A rule fires once at its own program position (690_200), which is
// the single pass the query walk also makes. 10 + 20 = 30 down each path.

import std/io
import std/store

std/store:new(pts, capacity: 8) { k: i64, a: i64, b: i64, c: i64 }
std/store:new(acc_rule) { v: 0[i64] }
std/store:new(acc_query) { v: 0[i64] }
std/store:new(out) { r: 0[i64], q: 0[i64] }

// A singleton is read at a program position, not walked — the two totals are
// republished into one watched store so the readout order is the source's.
std/store:watch(out)
! r x |> std/io:print.ln("rule {{ x:d }}")
! q y |> std/io:print.ln("query {{ y:d }}")

std/store:insert(pts) { k: 1, a: 10, b: 700, c: 900 }
| row _ |> _
| full |> _
std/store:insert(pts) { k: 2, a: 55, b: 701, c: 901 }
| row _ |> _
| full |> _
std/store:insert(pts) { k: 1, a: 20, b: 702, c: 902 }
| row _ |> _
| full |> _

// Lowering one: the standing rule, at its program position.
std/store:rule(pts)
! row e when e.k == 1 |> std/store:stored { acc_rule.v: acc_rule.v + e.a }

// Lowering two: the query walk over the same rows, same guard, same body.
std/store:query(pts)
! query r when r.k == 1 |> std/store:stored { acc_query.v: acc_query.v + r.a }

std/store:stored { out.r: acc_rule.v }
std/store:stored { out.q: acc_query.v }
