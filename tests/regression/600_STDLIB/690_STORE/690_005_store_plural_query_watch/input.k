// ASPIRATIONAL (RED by design until std/store rung 2 lands — see DESIGN.md).
// PLURALITY-NATIVE (ruling 2): the store IS the table; fields are column
// properties; rows are inserted at runtime. The query watch is the
// row-level subscription: its block is the store's OWN DSL (opaque
// source block, captured-style — ruling 6) carrying a PROJECTION
// (path destructure, punned: `entity.hp` binds `hp` — mandatory punning,
// so a redundant label like `kind: entity.kind` would be REJECTED; the
// rename here is genuine, `enemy_kind`) and a RENAME (`enemy_kind:
// entity.kind` — RHS-as-path is legal here precisely because this is NOT
// core destructure, whose RHS is claimed by type assertions, 020_016).
// The `when` guard sees the projected names (destructure+when on `!`:
// 020_035 GREEN) and compound guards are grounded (`and` in when-guards:
// 020_036 GREEN) — compiled into the write path; the queries are
// comptime-visible, which is what lets usage dictate layout (T4).
//
// PROVISIONAL spellings: `insert` (row-creation verb unruled — O2) and
// the branch name `query` (fire vocabulary unruled — O1, enter/leave/
// changed question).
// Three rows; the query matches hp > 40 AND enemy_kind == 1: only the 50.

import std/io
import std/store

std/store:new(game, capacity: 64) { hp: i64, kind: i64 }

std/store:query(game)
! query { entity.hp, enemy_kind: entity.kind } when hp > 40 and enemy_kind == 1 |> std/io:print.ln("enemy hp {{ hp:d }}")

std/store:insert(game) { hp: 30, kind: 1 }
std/store:insert(game) { hp: 50, kind: 1 }
std/store:insert(game) { hp: 60, kind: 2 }
