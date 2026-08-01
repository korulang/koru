// PINS: the chain-bind two-column swap (690_131's shape) at store scale —
// 10,000 rows, swept repeatedly under for-each. The bind re-binds per row per
// pass, and an ODD number of passes leaves every row exchanged exactly once
// net: a carries b's seed across all 10,000 rows.
//
// 690_131 pins the mechanism on two rows and one pass; this pins the same
// composition at the scale the sweep loop is vectorized for — insert under
// for-each x sweep nested under for-each x chain bind past the clobbering
// write. The checksum is the oracle: 10,000 rows x b-seed 2.0 = 20000.
import std/io
import std/store

tor echo { v: f64 } -> f64
echo -> v

std/store:new(cells, capacity: 10000) { a: f64, b: f64 }
std/store:new(check) { sum: 0.0[f64] }
std/store:new(out) { v: 0.0[f64] }

std/store:watch(out)
! v x |> std/io:print.ln("checksum {{ x:f }}")

for(0..10000)
! each _ |> std/store:insert(cells) { a: 1.0, b: 2.0 }

for(0..3)
! each _ |> std/store:query(cells)
    ! query e |> echo(v: e.a): t |> std/store:stored { e.a: e.b, e.b: t }

std/store:query(cells)
! query e |> std/store:stored { check.sum: check.sum + e.a }

std/store:stored { out.v: check.sum }
