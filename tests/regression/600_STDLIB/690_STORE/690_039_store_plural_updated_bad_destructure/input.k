// WALL: plural `! updated` binds the write contract — the written field's
// { old, new } images — never row fields. Destructuring a row field here
// confuses the lifecycle grammar (`inserted`/`removed` project ROW fields
// by pun; `updated` carries the DELTA) and must be rejected with a message
// that teaches the contract, at the koru level.

import std/io
import std/store

std/store:new(reserve) { pool: 0[i64] }

std/store:new(squad, capacity: 64) { hp: i64 }
! updated { hp } |> std/store:stored { reserve.pool: reserve.pool + hp }

std/store:insert(squad) { hp: 10 }
