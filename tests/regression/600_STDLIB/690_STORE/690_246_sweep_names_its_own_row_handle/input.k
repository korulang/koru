// PINS: `[id]` — a sweep can name the HANDLE of the row it is visiting.
//
// `[ordinal]` is WHERE the visit is. `[id]` is WHICH ROW it is standing on.
// Both are needed and neither substitutes for the other, which is why they are
// two annotations rather than one:
//
//   - a cell that names a row names it by HANDLE, never by position (ruled).
//     A take swap-removes the last row into the freed slot, so an ordinal
//     written to a column outlives its meaning by exactly one removal;
//   - so a body that wants to STORE a reference to itself needs the handle,
//     and until now the only place a handle was minted was `| row` at insert.
//     A sweep could address its row (`store[e]`) but could not name it.
//
// Both requests are synthesized ONLY when asked for — the demand-driven rule
// `[ordinal]` already carried.
//
// The consumer's spelling, and the reason this was built: an INTRUSIVE CHAIN.
// Each visited row reads the current head, writes it to its own `next`, then
// writes ITSELF as the new head — a bucket rebuild, the classic no-allocation
// spatial hash, needing no nested collection, no positional addressing and no
// verb beyond this annotation. Rows are visited 10, 20, 30, so the chain comes
// out 30 -> 20 -> 10, walked back through the handle reads 690_245 pins.
//
// `ordsum` rides alongside to pin that the two requests stay DISTINCT: the
// ordinals are 0, 1, 2 and sum to 3, while the same rows' ids are branded
// handles that address rows correctly. One value could not do both jobs.
//
// Found by the ECS benchmark's spatial grid (tests/benchmarks/003_ecs_reactive),
// which is the workload the vocabulary was waiting for before growing.
import std/io
import std/store

std/store:new(cells, capacity: 8) { v: i64, next: -1[i64] }
std/store:new(head) { h: -1[i64] }
std/store:new(acc) { ordsum: 0[i64] }
std/store:new(probe) { v1: 0[i64], v2: 0[i64], v3: 0[i64] }

std/store:insert(cells) { v: 10, next: -1 }
std/store:insert(cells) { v: 20, next: -1 }
std/store:insert(cells) { v: 30, next: -1 }

std/store:query(cells)
! query { [row]e, [ordinal]n, [id]h } |> std/store:stored { e.next: head.h }
    |> std/store:stored { head.h: h }
    |> std/store:stored { acc.ordsum: acc.ordsum + n }

std/store:stored { probe.v1: cells[head.h].v, probe.v2: cells[cells[head.h].next].v }
std/store:stored { probe.v3: cells[cells[cells[head.h].next].next].v }

std/io:print.ln("chain {{ probe.v1:d }} -> {{ probe.v2:d }} -> {{ probe.v3:d }} ordsum {{ acc.ordsum:d }}")
