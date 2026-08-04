// PINS the refusal: `[layout(...)]` must name a layout the grid IMPLEMENTS.
//
// This is the same discipline as 697_009's `[unsafe(bonuds)]`, and it matters
// for a sharper reason here. A misspelled facet on `[unsafe]` waives nothing
// and leaves the program SAFE while reading as unsafe -- bad, but conservative.
// A misspelled LAYOUT leaves the grid on the layout you were trying to change,
// so the program keeps the performance characteristic the author believed they
// had just replaced, and the annotation sits in the source as evidence that the
// decision was made. Nothing about the program's behaviour reveals it: the
// results are identical either way (697_010), so only a measurement would ever
// catch it, and only if someone thought to take one.
//
// So an unrecognised layout is refused, and the diagnostic names both layouts
// the grid actually has rather than only rejecting the input.
//
// 697_010 pins the accepting side, including the explicit `[layout(column)]`
// spelling of the default.
import std/io
import std/grid

[layout(rwo)]std/grid:new(cells, size: 8) { v: 0[i64] }

std/io:print.ln("unreachable")
