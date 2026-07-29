// A ONE-column store's watch arm is the STORE. Ruled by Lars 2026-07-29.
//
// `watch` is the only store construct whose arm names a COLUMN rather than a
// fixed word — `sweep`, `item`, `full`, `row`, `inserted`, `removed`, `updated`
// are all construct- or event-named. It names a column for one reason: a
// multi-column store makes the author choose which one.
//
// With one column there is nothing to choose, so the name collapses to the
// store's — the same rule the declaration, `stored` and the row bindings carry.
// Nothing new is reserved, and an author who knows the declaration rule can
// guess the arm without being told.
//
//     std/store:new(counter) { v: 0[i64] }   ->   { 0[i64] }
//     std/store:watch(counter) ! v e         ->   ! counter e
import std/io
import std/store

std/store:new(counter) { 0[i64] }

std/store:watch(counter)
! counter e |> std/io:print.ln("clicks {{ e:d }}")

std/store:stored { counter: 3 }
std/store:stored { counter: counter + 4 }
