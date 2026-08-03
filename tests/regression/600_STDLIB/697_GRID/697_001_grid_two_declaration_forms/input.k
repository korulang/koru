// PINS std/grid: a FIXED, POSITIONALLY-ADDRESSED, STATICALLY-ALLOCATED table.
//
// The distinction from a store is one question — CAN A ROW MOVE? A store's
// `take` swap-removes, so position is not identity, so a row is named by a
// generational handle and every access pays brand + bounds + generation. A grid
// forbids removal: every cell exists from declaration and none relocates, so
// POSITION IS IDENTITY and the apparatus is unnecessary. The emitted cell type
// carries no handle, no generation word, no sparse indirection, no freelist and
// no `len`. Because a grid can never take, it is on the dense vectorising path
// by construction rather than by analysis.
//
// This REPLACES the heap-boxed `std/grid` that came before it. That one was
// first-class — a `*Grid_i64` value you held, passed and freed — and its own
// header named the handle box as its only perf debt. Second-class-ness deletes
// exactly that debt, which is the same argument the store's O9 ruling makes:
// first-class values are why a reactive system needs a runtime.
//
// TWO DECLARATION FORMS, one construct:
//   size: N          a flat run of N cells; the index is the program's business,
//                    which is what a spatial hash wants (it writes its own `% N`)
//   dimensions: RxC  a bounded field, addressed `g[x, y]`, linearised row-major
//                    as `y*C + x` — the same layout the heap grid used and the
//                    same one hand-written Zig/C/Rust use
//
// `RxC` needs no grammar support: an invocation argument arrives as raw source
// text, so `4x5` is delivered whole and the transform parses it, exactly as
// `size: N` is parsed rather than lexed. It cannot collide with an identifier
// because an identifier may not start with a digit.
//
// Every column is SEEDED. A store column may be bare because a row is born at
// insert; a grid has no insert, so every cell must say what it starts as.
//
// The readback here is deliberately a value-dependent INDEX rather than a print:
// a grid read does not yet lower inside `print.ln`, so an out-of-range address
// computed from a cell's contents is the only value oracle at this rung. 41+1
// is 42, and 42 is outside an 8-cell grid, so the trap naming `buckets` proves
// both writes landed and the read saw them.
import std/io
import std/grid

std/grid:new(buckets, size: 8) { count: 0[i64] }
std/grid:new(lights, dimensions: 4x5) { on: 0[i64] }

std/grid:stored { buckets[2].count: 41 }
std/grid:stored { buckets[2].count: buckets[2].count + 1 }
std/grid:stored { lights[3, 2].on: 7 }
std/grid:stored { lights[3, 2].on: lights[3, 2].on * 6 }

std/io:print.ln("writes landed")
std/grid:stored { buckets[buckets[2].count].count: 0 }
std/io:print.ln("unreachable")
