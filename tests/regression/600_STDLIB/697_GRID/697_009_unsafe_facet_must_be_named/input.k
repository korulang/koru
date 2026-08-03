// PINS the refusal: `[unsafe]` on a grid must NAME what it waives.
//
// A bare `[unsafe]` is a blank cheque — it waives bounds today and silently
// widens to whatever check the construct grows next, with nobody re-consenting.
// `[unsafe(bounds)]` can only ever waive bounds.
//
// The sibling failure is a misspelled facet (`[unsafe(bonuds)]`), refused by
// the same code with the facet named back. That one matters more than it looks:
// a typo'd facet would waive NOTHING, keep the trap, and still read to every
// later reviewer as a place where safety had already been given up. An
// annotation that silently does nothing is worse than one that errors.
//
// 697_008 pins the accepting side.
import std/io
import std/grid

[unsafe]std/grid:new(cells, size: 8) { v: 0[i64] }

std/io:print.ln("unreachable")
