// 690_051 — CAPACITY selects the store shape (the 690_050 ruling, positive
// pin). `capacity: N` (N > 1) at create declares the reactive CONTAINER —
// rows grow from empty; insert/query address them. The DEFAULT capacity 1
// declares the reactive VALUE — always present, direct `store.field` access
// through stored/watch. Initialization stays orthogonal: the value store
// seeds `count: 0[i64]` (a column default), the container declares bare
// `n: i64` — neither spelling selects the shape; only capacity does.

import std/io
import std/store

std/store:new(items, capacity: 8) { n: i64 }

std/store:watch(items)
! row e |> std/io:print.ln("item {{ e.n:d }}")

std/store:new(tally) { count: 0[i64] }

std/store:watch(tally)
! count c |> std/io:print.ln("count {{ c:d }}")

std/store:insert(items) { n: 1 }
std/store:insert(items) { n: 2 }
std/store:stored { tally.count: tally.count + 1 }
