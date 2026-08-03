// PINS `[unsafe(bounds)]` on a grid declaration — the index floor waived BY
// NAME, at the one place that covers reads and writes together.
//
// WHY IT EXISTS, measured rather than assumed. The bounds compare is nearly
// free: the optimizer commons every access in a loop down to one per iteration.
// The cost is the failure EDGE — `@panic` is `noreturn`, which gives the loop a
// side exit LLVM's vectoriser refuses. On the boids steer loop that is 187ms
// against 99ms, and a branch that RETURNS is as fast as no check at all.
//
// The loud-and-fast version was tried first and does not exist: clamping the
// index and recording the violation in a flag, panicking after the sweep,
// measured 190ms — no better than the trap, because the flag is a memory write
// in the loop and that is a loop-carried dependency of its own. So the tradeoff
// is real, and it is spelled rather than inferred.
//
// AN ANNOTATION, NOT AN ARGUMENT. `size:` describes the table; waiving a check
// describes how it is compiled, and the language already has a form for that
// (`[comptime]tor`, `[pure]`, `[depends_on(x)]` — 310_031/310_033 are the green
// precedent for a parameterised annotation on a flow site carrying a block).
// It also makes the audit one grep for `[unsafe`, which an argument buried
// among `size:`/`dimensions:` would not be.
//
// AND IT NAMES THE FACET. A bare `[unsafe]` widens silently the day the grid
// grows a second check, with nobody re-consenting; `bounds` can only ever waive
// bounds. 697_009 pins both refusals — the bare form and an unknown facet.
//
// This test only asserts that the waived grid still computes correctly in
// range. What happens OUT of range is, by construction, not defined here and
// deliberately not tested.
import std/io
import std/store
import std/grid

[unsafe(bounds)]std/grid:new(cells, size: 8) { v: 0[i64] }
std/store:new(acc) { n: 0[i64] }

std/grid:stored { cells[3].v: 7 }
std/grid:stored { cells[5].v: 41 }

std/grid:sweep(cells)
! sweep c when c.v > 0 |> std/store:stored { acc.n: acc.n + c.v }

std/io:print.ln("sum {{ acc.n:d }} at {{ cells[5].v:d }}")
