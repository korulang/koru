// 690_049 — CONTAINER (capacity > 1) with MIXED scalar column types (i64 + f64).
// The remainder of 690_020 tier 1: singleton/value uniform-scalar columns ship
// (690_021 f64 GREEN), but CONTAINER rows are hardcoded [CAP]i64 (store.kz:~1056)
// with an i64-typed row struct (~:1073), so a non-i64 column in a rows store is
// silently mis-emitted / walled. ASPIRATIONAL (see TODO): typed SoA columns —
// each column its own array type, threaded through insert/stored/colRead.
// No ownership (scalars are values); string/reference tier is a LATER rung.
import std/io
import std/store

std/store:new(m, capacity: 8) { n: i64, r: f64 }

std/store:insert(m) { n: 5, r: 2.5 }

std/store:sweep(m)
! sweep e |> std/io:print.ln("n {{ e.n:d }} r {{ e.r:f }}")
