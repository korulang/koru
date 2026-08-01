// PROBE 1 — is `! step` reachable as a store interceptor?
//
// The store declaration already dispatches a fixed interceptor vocabulary
// (store.kz:1137 `discharge`, :1163 `inserted`/`removed`/`updated`). This asks
// what the compiler says about a name outside it — the answer names the
// insertion point for a pump arm.
import std/io
import std/store

std/store:new(batch, capacity: 2) { idx: i64 }
! step row |> std/io:print.ln("stepping")

std/io:print.ln("declared")
