// 690_057 — the DRAIN rung (ambiguous owned column). *Transaction<active!> has
// two dischargers (commit|rollback), so the store can't auto-tear-down. The
// store mints a whole-store <drain!> obligation at `new`; `std/store:drain`
// consumes it and yields each live element (with <active!> moved out) for the
// caller to pick commit/rollback. Draining discharges everything → green.
import std/io
import std/store
import app/lib/tx

std/store:new(txns, capacity: 8) { tx: *app/lib/tx:Transaction<active!> }

app/lib/tx:begin(): t1 |> std/store:insert(txns) { tx: t1 }
    | row _ |> _
app/lib/tx:begin(): t2 |> std/store:insert(txns) { tx: t2 }
    | row _ |> _

std/store:drain(txns)
| item it |> app/lib/tx:commit(it.tx) |> std/io:print.ln("drained-one")
