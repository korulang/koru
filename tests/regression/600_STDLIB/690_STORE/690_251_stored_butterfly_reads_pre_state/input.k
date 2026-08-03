// PINS the case that decides the semantics rather than merely illustrating it:
// a BUTTERFLY, where both entries read both fields.
//
//   stored { e.a: e.a + e.b, e.b: e.a - e.b }        3, 7  ->  10, -4
//
// RED ON PURPOSE. The implementation lands entries in written order, so the
// second rhs reads the `a` the first entry just wrote: 3+7=10, then 10-7=3,
// printing `a 10 b 3`. Pre-state gives 3+7=10 and 3-7=-4.
//
// WHY THIS ONE AND NOT JUST THE SWAP. A swap can be dismissed — "that is what
// `<->` is for, write the exchange". A butterfly cannot:
//
//   - it is NOT an exchange, so no exchange verb expresses it;
//   - it CANNOT become a chain of two blocks without a scratch column, because
//     the second entry needs `a`'s pre-state after `a` has been written, and
//     staging that through a column is the per-row memory traffic the whole
//     design is trying to delete;
//   - it is ordinary arithmetic that any numerical program writes without
//     thinking, and under written-order it silently computes something else.
//
// So the butterfly is the existence proof that pre-state is not a preference
// between two workable readings. Written-order does not have a spelling for
// this program at all.
//
// The lowering pre-state asks for is the obvious one, and it is why the
// "simultaneous needs temporaries" worry is smaller than it sounds: the temps
// ARE the loads, and only fields read-and-written by DIFFERENT entries need to
// outlive their own write.
//
//   const a0 = cells.a[row];
//   const b0 = cells.b[row];
//   cells.a[row] = a0 + b0;
//   cells.b[row] = a0 - b0;
//
// Two stores with no dependency between them, to different columns — free to
// reorder, free to vectorise across rows. The written-order version is a
// store-to-load chain through memory, which is what stops a vectoriser.
//
// Ruled with Lars 2026-08-03; see 690_126 for the ruling and its history.
import std/io
import std/store

std/store:new(cells, capacity: 2) { a: f64, b: f64 }

std/store:insert(cells) { a: 3.0, b: 7.0 }

std/store:query(cells)
! query e |> std/store:stored { e.a: e.a + e.b, e.b: e.a - e.b }

std/store:query(cells)
! query r |> std/io:print.ln("a {{ r.a:f }} b {{ r.b:f }}")
