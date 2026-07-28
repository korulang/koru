// PINS: a `! sweep` arm can WRITE the row it is standing on, not only read it.
//
// `query` already does this — 690_008 is
// `! query { entity.hp, … } when kind == 1 |> std/store:stored { entity.hp: … }`
// — and sweep is query's momentary, nestable twin. The same write in a sweep
// arm is refused, and the diagnostic reads the projection name as a store:
//
//     std/store:stored: unknown store 'entity' - no std/store:new(entity) found
//
// The guard is fine: `! sweep { … } when idx == target` parses and is accepted.
// Only the write is unwired.
//
// This is the difference between a store you can render and a store you can
// MAINTAIN from a running program. `query` is top-level-only by design — it is
// a standing rule fused into the write paths — so a nested body that has to
// update one row has no verb at all today: keyed addressing is unbuilt
// (690_018 is an ASPIRATION pin, spelling still provisional), and take+insert
// swap-removes, which shuffles the very row ordinals a renderer lays out by.
//
// Found writing koru-examples/downloads, where curl's `! progress pr` names
// WHICH transfer moved (`pr.index`) and the program wants to bump that row's
// percent. Three concurrent bars need it; one shared cell is not information.
//
// SIBLING GAP, not pinned here: a sweep body cannot reference the enclosing
// EVENT's parameters either — captures collects mid-chain binds (690_073) and
// not inputs — so the guard above reaches `target` while a body reaching `v`
// gets `use of undeclared identifier 'v'`.
import std/io
import std/store

std/store:new(rows, capacity: 8) { idx: i64, pct: 0[i64] }

std/store:insert(rows) { idx: 0, pct: 0 }
| row _ |> _
std/store:insert(rows) { idx: 1, pct: 0 }
| row _ |> _

std/store:sweep(rows)
! sweep { entity.idx, entity.pct } when idx == 1 |> std/store:stored { entity.pct: 77 }

std/store:sweep(rows)
! sweep { entity.idx, entity.pct } |> std/io:print.ln("idx {{ idx:d }} pct {{ pct:d }}")
