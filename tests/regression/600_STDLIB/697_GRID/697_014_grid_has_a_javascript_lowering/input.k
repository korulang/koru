// PINS: std/grid has a JAVASCRIPT lowering — the same declaration, write and
// read that run on the Zig lane run under --lang=js. The type object keeps
// the Zig artifact's names (`__KoruGridT_<g>.__koru_at` / `__koru_wide`,
// `__koru_grid_<g>`), so the one shared `grid_read.lower` resolves against
// either target's declaration; the write unit's proc carries the target tag.
// Before this lowering existed the JS emitter met the write unit's |zig proc
// and PANICKED (NoJsProcBody) — a grid program had no JS path at all.
// The read-back through a second write's value and a fmt interpolation pins
// that reads lower everywhere, not only inside write blocks.

import std/io
import std/grid

std/grid:new(xref, size: 4) { h: 0[i64] }

std/grid:stored { xref[1].h: 5 }
std/grid:stored { xref[2].h: xref[1].h + 1 }

std/io:print.ln("cell1 {{ xref[1].h:d }} cell2 {{ xref[2].h:d }}")
