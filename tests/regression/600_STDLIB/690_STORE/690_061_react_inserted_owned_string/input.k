// 690_061 — REACT over an OWNED column: an `inserted` lifecycle interceptor
// fires in the insert write path (690_029) and BORROW-READS the just-inserted
// owned String — 690_060's bare-borrow projection (*std/string:String<view>,
// no `!`) threaded into a REACTIVE arm instead of a query body. The store keeps
// the live <instance!>; the interceptor gets `label` as a bare borrow, reads
// it, owes nothing; teardown frees each live element. First REACT-over-owned
// rung (READ landed in 690_060; watch/interceptor over owned was the wall).
//
// Currently WALLED at store.kz:~1410 (lifecycle interceptors on an owned-column
// store are a later rung). This pins the TARGET — MUST_RUN, red until it lands.
import std/io
import std/string
import std/store

std/store:new(log, capacity: 8) { label: *std/string:String<std/string:instance!> }
! inserted { label } |> std/string:read(s: label): text |> std/io:print.ln("logged: {{ text:s }}")

std/string:from-page(text: "hello")
| ok s |> std/string:take(s): owned |> std/store:insert(log) { label: owned }
    | row _ |> _
| err _ |> _

std/string:from-page(text: "world")
| ok s2 |> std/string:take(s: s2): owned2 |> std/store:insert(log) { label: owned2 }
    | row _ |> _
| err _ |> _
