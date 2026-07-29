// 690_057 — ambiguous owned column, discharged via a bolted-on `! discharge`
// branch. *Transaction<active!> has TWO dischargers (commit|rollback), so the
// store can't pick — it requires the discharger to be declared AT the store (the
// store is static/program-lifetime, so its discharger is static too). Teardown
// (program exit) fires `! discharge item` per still-live element; the item holds
// <active!>, so the phantom checker forces the handler to discharge it.
//
// ONE column, so `item` IS the transaction — not a record wrapping it. The
// two-column shape is 690_097's control.
import std/io
import std/store
import app/lib/tx

std/store:new(txns, capacity: 8) { tx: *app/lib/tx:Transaction<active!> }
! discharge item |> app/lib/tx:commit(tx: item)

app/lib/tx:begin(): t1 |> std/store:insert(txns) { tx: t1 }
    | row _ |> _
app/lib/tx:begin(): t2 |> std/store:insert(txns) { tx: t2 }
    | row _ |> _

std/io:print.ln("inserted")
