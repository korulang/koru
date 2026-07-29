import std/io
import std/store
import app/lib/pend

std/store:new(batch, capacity: 2) { *app/lib/pend:Pending<open!> }
! discharge _ |> app/lib/pend:cancel(): n |> std/io:print.ln("cancelled {{ n:d }}")

app/lib/pend:start(): p |> std/store:insert(batch) { p }
    | row _ |> _

std/io:print.ln("inserted")
