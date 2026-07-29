import std/store
import app/lib/pend

std/store:new(batch, capacity: 2) { *app/lib/pend:Pending<open!> }

app/lib/pend:start(): p |> std/store:insert(batch) { p }
    | row _ |> _
