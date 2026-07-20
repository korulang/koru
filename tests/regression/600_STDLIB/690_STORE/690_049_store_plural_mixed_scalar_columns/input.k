// 690_049 — PLURAL store with MIXED scalar column types (i64 + f64). The
// remainder of 690_020 tier 1: singleton uniform-scalar columns already ship
// (690_021 f64 GREEN), but PLURAL rows are hardcoded [CAP]i64 (store.kz:1056)
// with an i64-typed row struct (:1073) and a single value_type (:499), so a
// non-i64 column in a rows store is silently mis-emitted / walled.
// ASPIRATIONAL (see TODO): typed SoA columns — each column its own array type,
// threaded through insert/stored/colRead. No ownership (scalars are values);
// the reference/string tier that needs take-discharge is a LATER rung.
import std/io
import std/store

std/store:new(m) { n: i64, r: f64 }

std/store:insert(m) { n: 5, r: 2.5 }

std/store:query(m)
! query { entity.n, entity.r } |> std/io:print.ln("n {{ n:d }} r {{ r:f }}")
