// A store with TWO columns keeps the ROW RECORD in its `! discharge` payload.
//
// This is the control for the one-column identity lowering: arity picks the
// payload shape, so at two columns `item` is a record and `item.<field>` is the
// only way to reach a column. The 2026-07-21 per-field reissue reason is live
// here — `tx` carries an obligation, `n` does not, and one payload has to carry
// both.
import std/io
import std/store
import app/lib/tx

std/store:new(txns, capacity: 8) { tx: *app/lib/tx:Transaction<active!>, n: i64 }
! discharge item |> app/lib/tx:commit(item.tx)

app/lib/tx:begin(): t1 |> std/store:insert(txns) { tx: t1, n: 1 }
    | row _ |> _
app/lib/tx:begin(): t2 |> std/store:insert(txns) { tx: t2, n: 2 }
    | row _ |> _

std/io:print.ln("inserted")
