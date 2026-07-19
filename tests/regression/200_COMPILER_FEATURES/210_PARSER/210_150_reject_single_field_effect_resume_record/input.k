// Single-entry records collapse to the scalar in the effect-arm RESUME position
// too: legal is `! ask -> i64` or `! ask -> { a, b, ... }`, never `! ask -> { a }`.
// The sibling of 210_149 (bare-return) and 210_063 (branch payload) for the `->`
// resume slot. Fork-independent: whichever way a direct record resume is ruled, a
// one-field resume record is illegal — it must collapse to `! ask -> i64`. The
// intended rejection is a parser diagnostic guiding to the scalar form.
import std/io
pub event request { seed: i64 }
! ask -> { a: i64 }
| done i64
request = ask(): c => done c.a
request(seed: 8)
! ask -> { a: 42 }
| done r |> std/io:print.ln("{{ r:d }}")
