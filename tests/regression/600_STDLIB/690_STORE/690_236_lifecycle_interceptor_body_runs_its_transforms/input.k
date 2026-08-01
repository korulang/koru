// PINS: a lifecycle interceptor's body is ordinary Koru, so a comptime
// transform inside it expands the way it does anywhere else.
//
// `! inserted` and `! removed` are wired — the store calls both handlers at the
// write and before the swap-remove — and each body here is a single
// `std/io:print.ln`, which is `~[keyword|comptime|transform]` (io.kz:240): a
// call site the transform REWRITES into inline Zig at compile time. The two
// prints outside the declaration are the control, lowered on the ordinary path.
//
// This is the store's face of frag-two-lowerings-share-one-contract. An
// interceptor body is emitted as a synthesized subflow, and every contract a
// body can see has to hold on that path too — otherwise a store's interceptor
// silently accepts surface it cannot run, which reads exactly like a wired one.
import std/io
import std/store

std/store:new(batch, capacity: 2) { idx: i64 }
! inserted { idx } |> std/io:print.ln("inserted {{ idx:d }}")
! removed { idx } |> std/io:print.ln("removed {{ idx:d }}")

std/io:print.ln("before")
std/store:insert(batch) { idx: 7 }
| row _ |> std/store:take(batch[0])
    | item _ |> std/io:print.ln("took it")
    | empty |> std/io:print.ln("empty")
| full |> std/io:print.ln("full")
