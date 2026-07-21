// 690_058 — the drain ENFORCEMENT (negative). An ambiguous *Transaction<active!>
// column with NO `! discharge` handler bolted onto the store: the store refuses
// the declaration (teaching error at the store), so the insert never consumes
// t1's obligation and the undischarged-obligation leak fires loudly (KORU030:
// "multiple discharge options: rollback, commit"). Proves koru FORCES the drain
// (no silent drop of ambiguous elements).
import std/store
import app/lib/tx

std/store:new(txns, capacity: 8) { tx: *app/lib/tx:Transaction<active!> }

app/lib/tx:begin(): t1 |> std/store:insert(txns) { tx: t1 }
    | row _ |> _
