// PLURAL `! updated { old, new }` — the write-contract lifecycle on rows
// (Ruling 5: stores emit inserted/updated/removed; this is the plural
// `updated` face). The payload is the (c)-lean write contract mirrored
// from the singleton (690_003): old/new are the WRITTEN FIELD's images,
// usage-synthesized — the pre-image read happens inside the write's
// atomic step because a body binds it.
//
// The canonical use: cross-store aggregate coherence under damage. Every
// hp write flows its delta into a singleton reserve — the arena
// showcase's enemy-hp-pool need. The interceptor is the store's CONTRACT
// and fires BEFORE subscriptions observe the settled row (no torn state:
// by the time the field watch reports the new hp, the aggregate agrees).
//
// Births are not writes (O9/O9b, as pinned green in 690_008): the inserts
// produce no pool lines and no hp lines. The sweep then writes two rows;
// each write fires the interceptor once (per-row, repeatable) and the
// watch once, interceptor first.

import std/io
import std/store

std/store:new(reserve) { pool: 0[i64] }

std/store:new(squad, capacity: 64) { hp: i64, kind: i64 }
! updated { old, new } |> std/store:stored { reserve.pool: reserve.pool + new - old }

std/store:watch(reserve)
! pool p |> std/io:print.ln("pool {{ p:d }}")

std/store:watch(squad)
! hp h |> std/io:print.ln("hp now {{ h:d }}")

std/store:insert(squad) { hp: 40, kind: 1 }
std/store:insert(squad) { hp: 60, kind: 2 }
std/store:insert(squad) { hp: 80, kind: 1 }

std/store:sweep(squad)
! sweep e when e.kind == 1 |> std/store:stored { e.hp: e.hp - 15 }
