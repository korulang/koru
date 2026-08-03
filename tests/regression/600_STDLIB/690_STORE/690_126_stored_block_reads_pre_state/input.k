// PINS: every rhs in a `stored` block reads PRE-STATE. A block is ONE write,
// not a sequence of them, so no entry can observe another entry's result.
//
// RED ON PURPOSE. The implementation currently lands entries in written order
// and lets a later rhs read what an earlier one wrote, so this prints
// `a 7 b 7` — the row duplicated — where the design says `a 7 b 3`.
//
// THIS TEST USED TO PIN THE BUG AS THE RULING, and that is the more important
// part of its history. It was called `690_126_stored_block_writes_land_in_order`
// and its expectation was `a 7 b 7`, written from observing what the compiler
// did rather than from the design. Its own header admitted the question "was
// never asked" and left a note about a possible future ruling — and then
// 690_128 was written on top, citing this test as the licence for factoring a
// determinant into a column and dividing by it in sixteen later entries of the
// same block. A green test is authority here, so an accident of lowering became
// specification, and a second test then depended on it.
//
// The design (`frag-std-store-design`, the 2026-07-04 spine) says the opposite
// in one line: "Writes interleave, never overlap: write + full cascade is the
// atomicity unit; the chain is the envelope lean covers multi-write grouping."
// A block is one transaction. Multi-write GROUPING is what the chain is for.
//
// WHY IT HAS TO BE THAT WAY, since a pin that only cites a document teaches
// nothing: subscriptions are compiled INTO the write path. If a block were a
// sequence of writes, each entry would drag its own cascade, and a watch on
// `b` would be invoked against a row where `a` has already moved and `b` has
// not — a state the program never intended to exist. Order-dependence would
// also make the cascade order-dependent, so reordering two entries in a record
// would silently change what subscribers observe. And it is what lets the
// compiler move the work: with no intra-block dependencies there is nothing to
// alias, so the block is a column-to-column map the vectoriser can take.
//
// Ruled with Lars 2026-08-03. The migration this implies is real and is not
// done here: 690_128 and 690_129 both exploit the overlap and must become
// chains of two blocks when the write path is fixed.
import std/io
import std/store

std/store:new(cells, capacity: 2) { a: f64, b: f64 }

std/store:insert(cells) { a: 3.0, b: 7.0 }

std/store:query(cells)
! query e |> std/store:stored { e.a: e.b, e.b: e.a }

std/store:query(cells)
! query r |> std/io:print.ln("a {{ r.a:f }} b {{ r.b:f }}")
