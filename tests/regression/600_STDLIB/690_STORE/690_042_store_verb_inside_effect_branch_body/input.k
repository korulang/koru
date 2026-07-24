// GREEN COVERAGE PIN (2026-07-18): a MOMENTARY store verb (insert) inside an
// inlined effect-branch body resolves and runs. Before this pin, every 690
// test placed store verbs at flow root — zero coverage of nesting — and a
// probe failure was briefly misdiagnosed as a scan-context resolution bug.
// It is not one: the registry IS reachable from spliced bodies; this pin
// keeps that true.
//
// The full placement ruling (Lars, 2026-07-18), for which this pin is the
// legal-side coverage:
//   - Stores are declared TOP-LEVEL.
//   - MOMENTARY verbs (insert / take / stored-through-cursor) are runtime
//     acts on an existing corpus: legal anywhere a body runs. (This pin.)
//   - Standing-rule INSTALLATIONS (watch, query-as-standing-rule) are
//     comptime-fused: TOP-LEVEL ONLY. In-body installation currently dies
//     with a misleading "unknown store" — the real gap is the DIAGNOSTIC
//     (should be a std/trellis placement law with a teaching message).
//   - stripe on a PLURAL store is unimplemented everywhere (root or body):
//     "later slice" per its own error — the actual feature gap for
//     per-frame rule firing.
//
// Surfaced by koru-libs/raylib (store-as-game-state probe,
// raylib/tests/bounce.k).

import std/io
import std/store

std/store:new(game, capacity: 64) { hp: i64 }

pub tor beat { x: i64 }
! tick i64

beat = tick(x)

beat(x: 7)
! tick t |> std/store:insert(game) { hp: t }
    | row _ |> _
    | full |> _

std/store:query(game)
! query { entity.hp } |> std/io:print.ln("hp {{ hp:d }}")
