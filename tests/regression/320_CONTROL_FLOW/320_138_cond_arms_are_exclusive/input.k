// RED BY DESIGN (pinned 2026-07-25). `cond` is multi-way DISPATCH (320_133),
// which means exclusive first-match: the arm whose guard matches runs, and the
// rest do not. Emission does not do that — every arm is emitted as a bare
// `if (guard) { body }` with NO `return`, so all arms evaluate in sequence and
// a later guard reads state an earlier arm just mutated.
//
// Here arm 1 sets v := 0, then arm 2's guard (`v == 0`) is now true and undoes
// it. Exclusive dispatch prints v=0; today it prints v=1 (SHOWN 2026-07-25).
//
// This is not academic: it silently breaks every toggle written as a cond.
// koru-examples' gallery had `clocks-keys` in exactly this shape — space set
// running := 0 and the next arm set it straight back, so the timer never
// paused. Compare the branch-group path, which DOES emit the exclusive chain
// (`if (guard) { body; return; }` — emitter_helpers.zig), so the same arms
// written as `| page when ...` siblings behave correctly. Two dispatch
// constructs, two different answers for the same source shape.
//
// WHERE THE FIX IS NOT (checked 2026-07-25, so the next attempt can skip it):
// not `koru_std/control.kz`. That template reads
//   {% if arm.guard != "" %}if ({{ arm.guard }}) { ... }{% else %}{ ... }{% endif %}
// and for EFFECT-position arms `arm.guard` is EMPTY — the guard has already been
// baked into `arm.continue` by the emitter. So every arm renders through the
// guardless `{% else %}` path as a bare block and the template's first-match
// branch is dead code here. Emitted shape, verbatim:
//   { const x = ch; _ = &x; { if (g1) { body1 } } }
//   { const x = ch; _ = &x; { if (g2) { body2 } } }
//   { {  } }
// `else`-chaining the template was tried and is INERT for exactly this reason
// (the value pins 320_133/137 stayed green because they take the same dead
// path). The fix is emitter-side, in how continuation bodies are generated for
// template procs — machinery `if` / `for` / `cond` share, hence the wider blast
// radius and why this is pinned rather than patched.
import std/io
import std/store

std/store:new(s) { v: 1[i64] }

tor toggle { ch: u8 }
toggle = cond(ch)
| c x when x == 't' and s.v == 1 |> std/store:stored { s.v: 0 }
| c x when x == 't' and s.v == 0 |> std/store:stored { s.v: 1 }
| c _ |> _

toggle(ch: 't')
std/io:print.ln("v={{ s.v:d }}")
