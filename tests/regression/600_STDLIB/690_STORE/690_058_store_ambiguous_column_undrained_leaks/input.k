// 690_058 — the drain ENFORCEMENT (negative). An ambiguous *Transaction<active!>
// column with NO `! discharge` handler bolted onto the store. Proves koru FORCES
// the drain: no silent drop of ambiguous elements.
//
// The diagnostic is KORU160, and WHERE it points is half the pin. The store
// declaration is what is wrong — a store that cannot say how it drains — so the
// error is spoken by the store transform, located at the declaration, and it
// names `! discharge` as the fix. An insert of an ambiguous column also leaks
// its obligation, and KORU030 would report that at the CALL SITE, which is
// correct code; the store speaks during the transform phase, so the analysis
// pass that would say the confusing thing never runs.
import std/store
import app/lib/tx

std/store:new(txns, capacity: 8) { tx: *app/lib/tx:Transaction<active!> }

app/lib/tx:begin(): t1 |> std/store:insert(txns) { tx: t1 }
    | row _ |> _
