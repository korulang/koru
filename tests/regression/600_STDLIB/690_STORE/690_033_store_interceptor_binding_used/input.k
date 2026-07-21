// The counterpart to 690_032: when a `removed` interceptor actually USES its
// bound row field, the binding is legal and the value threads into the body.
// Here `removed { hp }` subtracts the departing row's hp from a running total
// — the row's outgoing values are exactly what the take path supplies. This
// pins that the KORU100 usage check for interceptor payloads does not
// over-reject a genuinely-consumed binding.

import std/io
import std/store

std/store:new(stats) { total: 0[i64] }

std/store:new(pool, capacity: 64) { hp: i64 }
! removed { hp } |> std/store:stored { stats.total: stats.total - hp }

std/store:watch(stats)
! total t |> std/io:print.ln("total {{ t:d }}")

std/store:insert(pool) { hp: 7 }
| row b |> std/store:take(pool[b])
    | item _ |> _
