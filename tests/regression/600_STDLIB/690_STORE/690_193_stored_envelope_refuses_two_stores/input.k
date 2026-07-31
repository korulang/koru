// PINS: the REFUSAL of a multi-field stored envelope spanning TWO stores —
// the envelope is one atomic unit against one store ((i) chain-envelope,
// 690_009), and an entry addressing a second store is refused with BOTH
// stores named, not silently split into two units. The legal spelling is a
// chained pair of stored statements (690_190/690_194 lean on it for the
// per-row f64 counter this program is the collapsed form of).
import std/io
import std/store

std/store:new(cells, capacity: 2) { x: f64 }
std/store:new(acc) { t: 0.0[f64] }

std/store:insert(cells) { x: 1.0 }

std/store:sweep(cells)
! sweep e |> std/store:stored { e.x: acc.t, acc.t: acc.t + 0.5 }
