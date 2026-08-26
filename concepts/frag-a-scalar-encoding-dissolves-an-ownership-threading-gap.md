---
type: belief
id: frag-a-scalar-encoding-dissolves-an-ownership-threading-gap
provenance: AoC-2015 close-out session 2026-08-26 — day 10's "impossible across iterations" ledger died to a base-10 encoding after the qualified-phantom machinery it blamed had already gone green
ts: 2026-08-26
---

# When a red ledger blames owned-buffer threading, check whether the domain value fits a machine word first (belief)

Two corpus climbs have now reported "Koru cannot hand an owned, growing
buffer across iterations" where the pinned task's actual value fit in an
i64 all along:

- Day 11 (password search): encoded the 8-letter password as base-26 —
  the label fold threads a SCALAR; no buffer crosses anything.
- Day 10 (look-and-say): its ledger spent weeks describing the growing
  digit sequence as `*List_i64<list!>` that must transfer per round —
  while the sequence at statement scale is a six-digit number. Base-10
  packing turned five rounds into five chained scalar binds and went
  green the same hour the previous commit's emitter fix landed.

The rule this states: **the obligation system's hardest question
(ownership transfer across iteration boundaries) is sometimes not this
task's question.** Before building transfer machinery — fold-payload
handles, consume/reissue round-trips, store-backed pools — encode the
domain value arithmetically if its alphabet and bound allow, and let the
round be a pure function.

## Boundary conditions (stated, so the belief stays falsifiable)

- This is a PIN-SCALE honesty trade, identical to day 11's fixed
  8-letter alphabet: day 10's real inputs run 40 rounds and overflow any
  fixed word. The test header must say so plainly; growable surfaces
  remain the answer for personal-scale inputs.
- It does NOT generalize to tasks whose value is genuinely textual or
  unbounded (day 19's molecules are next and may hit exactly this wall).

## Consequences

- A red ledger's GAP section is a hypothesis about the language, but its
  ENCODING is a hypothesis about the task — both need checking before
  either is believed.
- Scalar rounds compose with the cheapest recursion idiom (bind-a-call,
  320_096) and never touch captures, folds-with-handles, or the
  auto-discharge pass.

Pinned by: `810_101_day10_part1` (green 2026-08-26), precedent
`810_111_day11_part1`.
