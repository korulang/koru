// The user's query, hand-tagged. A hurt enemy (hp 30, kind 2) among healthy
// rows is selected by guard conjunction over a value column and a kind tag:
// `when e.kind == 2 and e.hp < 40`. The tag is hand-written today — the
// aspiration is that the store SYNTHESIZES it from proto homes on usage, and
// `is Enemy` spells what `kind == 2` handwrites. When that lands, this test's
// manual tag deletes and the query keeps passing; the shared Health extent
// (690_272) feeds `hp` from one column. Guard shape per 690_008.
import std/io
import std/store

std/store:new(arena, capacity: 8) { hp: i64, kind: i64 }

std/store:insert(arena) { hp: 98, kind: 1 }
std/store:insert(arena) { hp: 72, kind: 2 }
std/store:insert(arena) { hp: 30, kind: 2 }

std/store:query(arena)
! query e when e.kind == 2 and e.hp < 40 |> std/io:print.ln("hurt enemy {{ e.hp:d }}")
