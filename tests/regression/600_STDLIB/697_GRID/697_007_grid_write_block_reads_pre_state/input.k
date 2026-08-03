// PINS: a grid write block reads PRE-STATE — and this one is GREEN.
//
// The same two programs 690_126 and 690_251 pin red for the store: a swap and
// a butterfly. std/grid already gets both right, because its write evaluates
// every operand at the SITE and only then assigns, so no entry can observe
// another entry's result.
//
// The pair matters more than either half. Two sibling tables, one syntax, two
// answers — the store duplicates the row and the grid exchanges it — and
// nothing in the corpus could see that until these three tests existed side by
// side. It was found by writing `stored { v.a: v.b, v.b: v.a }` against both
// on the same afternoon and getting different numbers.
//
// So the store's behaviour is not "the semantics of a write block in Koru". It
// is one table's implementation, contradicted by its sibling and by the design
// (`frag-std-store-design`: "Writes interleave, never overlap"). This test is
// the evidence that pre-state is implementable and already implemented — the
// fix to the store has a working reference in the same repository.
//
// Ruled with Lars 2026-08-03.
import std/io
import std/grid

std/grid:new(cells, size: 4) { a: 0.0[f64], b: 0.0[f64] }

std/grid:stored { cells[0].a: 3.0, cells[0].b: 7.0 }
std/grid:stored { cells[1].a: 3.0, cells[1].b: 7.0 }

// An exchange: neither entry may see the other's write.
std/grid:stored { cells[0].a: cells[0].b, cells[0].b: cells[0].a }

// A butterfly: both entries read both fields.
std/grid:stored { cells[1].a: cells[1].a + cells[1].b, cells[1].b: cells[1].a - cells[1].b }

std/io:print.ln("swap {{ cells[0].a:f }} {{ cells[0].b:f }} butterfly {{ cells[1].a:f }} {{ cells[1].b:f }}")
