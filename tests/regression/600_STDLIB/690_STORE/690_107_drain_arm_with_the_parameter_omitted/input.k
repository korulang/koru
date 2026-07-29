// The drain arm's binding reaches the call's one unfilled parameter.
//
// 690_106 is this program with `p: item` written. Here the label is dropped and
// the arm's binding is the only live `*Pending<!open>` in scope, so the argument
// thread has exactly one candidate for exactly one open slot — the ordinary
// by-type fill (210_191/192/194), which selects by TYPE and never by name.
//
// The store SYNTHESIZES this arm, and that is the whole difficulty: the thread
// normalizes authored surface, and a synthesized arm is born to the right of
// every pass that would fill it. 690_094 is the same question wearing `| full`;
// this is its `! discharge` face, and the two share a fix.
//
// What makes this the sharper of the pair: the store's own refusal, when the
// binding is dropped entirely, teaches `! discharge item |> ...(<param>: item)` —
// so the diagnostic prescribes the written label because the fill cannot be
// relied on. When the fill lands, that teaching is free to shrink.
//
// The failure this guards against is not a miscompile. It is that the obligation
// checker reports the unfilled parameter as the BINDING's fault — "Resource
// 'item' obligation <open!> was not discharged" — which sends the author to
// discharge a value they already piped into the one call that discharges it.
import std/io
import std/store
import app/lib/pend

std/store:new(batch, capacity: 2) { *app/lib/pend:Pending<open!> }
! discharge item |> app/lib/pend:cancel(): n |> std/io:print.ln("cancelled {{ n:d }}")

app/lib/pend:start(): p |> std/store:insert(batch) { p }
    | row _ |> _

std/io:print.ln("inserted")
