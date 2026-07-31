// PINS: 690_124's row-by-row rebuild at the serialize workload's scale and
// width — 1,000 rows, THREE columns of two scalar types (id/hp i64, x f64),
// each row given a DISTINCT f64 via a chained pair of stored writes (an f64
// running counter in a singleton; the pair is two statements because one
// envelope refuses to span two stores). The rebuild sweep feeds all three
// projections into the second store's insert literal; the copy is then read
// back independently.
//
// The oracle over the COPY: row count, sum(id) = 499500, sum(hp) = 1499500,
// sum(x) = 0.5 * 499500 = 249750 (halves — exact in f64).
//
// This is the projection half of the serialize hole: f64 crosses store to
// store ONLY this way — there is no float text path (std/string has
// parse-int/from-int, no float mirror), so 690_190's text round-trip cannot
// carry this store's x column.
import std/io
import std/store

std/store:new(cells, capacity: 1000) { id: i64, hp: i64, x: f64 }
std/store:new(copy, capacity: 1000) { id: i64, hp: i64, x: f64 }
std/store:new(acc) { t: 0.0[f64] }
std/store:new(check) { rows: 0[i64], ids: 0[i64], hps: 0[i64] }
std/store:new(checkx) { xs: 0.0[f64] }

for(0..1000)
! each i |> std/store:insert(cells) { id: @as(i64, @intCast(i)), hp: 1000 + @as(i64, @intCast(i)), x: 0.25 }

std/store:sweep(cells)
! sweep e |> std/store:stored { e.x: acc.t } |> std/store:stored { acc.t: acc.t + 0.5 }

std/store:sweep(cells)
! sweep s |> std/store:insert(copy) { id: s.id, hp: s.hp, x: s.x }

std/store:sweep(copy)
! sweep c |> std/store:stored { check.rows: check.rows + 1, check.ids: check.ids + c.id, check.hps: check.hps + c.hp } |> std/store:stored { checkx.xs: checkx.xs + c.x }

if(check.rows > 0)
| then |> std/io:print.ln("rows {{ check.rows:d }} ids {{ check.ids:d }} hps {{ check.hps:d }} xs {{ checkx.xs:f }}")
| else |> _
