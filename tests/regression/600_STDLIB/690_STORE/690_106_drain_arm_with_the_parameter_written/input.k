// The drain arm, with its parameter written. The control for 690_107.
//
// One owned column with no discharger the store can fire, so the store demands a
// `! discharge` arm; the arm binds the column itself (arity picks the payload
// shape), and `cancel(p: item)` hands it over by name. `cancel` returns a value,
// which is exactly why the store cannot fire it unattended — here the arm takes
// the return and prints it.
//
// Everything 690_107 needs is proven sound by this test EXCEPT the one token it
// drops: the written label.
import std/io
import std/store
import app/lib/pend

std/store:new(batch, capacity: 2) { *app/lib/pend:Pending<open!> }
! discharge item |> app/lib/pend:cancel(p: item): n |> std/io:print.ln("cancelled {{ n:d }}")

app/lib/pend:start(): p |> std/store:insert(batch) { p }
    | row _ |> _

std/io:print.ln("inserted")
