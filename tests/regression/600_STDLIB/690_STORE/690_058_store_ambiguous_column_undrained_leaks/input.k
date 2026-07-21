// 690_058 — the drain ENFORCEMENT (negative). An ambiguous *Transaction<active!>
// column that is NEVER drained: the store's whole-store <drain!> obligation is
// never discharged → a loud leak/undischarged-obligation error. Proves koru
// FORCES the drain (no silent drop of ambiguous elements).
import std/store
import app/lib/tx

std/store:new(txns, capacity: 8) { tx: *app/lib/tx:Transaction<active!> }

app/lib/tx:begin(): t1 |> std/store:insert(txns) { tx: t1 }
    | row _ |> _
