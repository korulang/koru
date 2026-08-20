---
type: belief
id: frag-a-produce-equals-scan-skips-comparisons
provenance: 2026-08-20 — koru-libs/asteroids sim:collide; `unknown tor 'm:= b'` and a tap-transformer OOB on the empty-path flow it minted
ts: 2026-08-20
---

# The impl-equals scan must skip comparison operators

`findTopLevelEquals` is asked "does this line carry a top-level `=`?" to
distinguish an implementation flow (`t = body`) from a produce
(`t -> expr`). It used to answer YES inside `==`, `<=`, `>=`, `!=` too —
comparison operators contain a bare `=` at depth 0.

So a bare-produce body carrying a comparison (`collide -> (a-b) <= (e+f)`)
split at the comparison's `=`: the body was re-read as `t = a = b`, minting
a **bogus flow whose event name is the tail after the split** (`= b`), which
resolved as `unknown tor 'm:= b'` — and when the module was large enough,
the empty-path head OOBed the tap transformer instead.

The rule: the equals scan recognizes only the impl `=` and the construct
`=>` — never a `=` that is part of `==`, `<=`, `>=`, `!=` (next char `=`, or
preceding char `= < > !`). This is why `a > (b - c)` worked while
`(a) <= b` — the checker rejected the paren-left form with a clean
diagnostic — but `a == b` / `a <= b` split into garbage.

## The two failure modes are ONE root

The tap-transformer OOB was not a second bug: the misparse minted an
empty-path flow, and the tap pass indexed `segments[0]` on it. One root
cause, two symptoms — which is why the OOB disappeared once the scan
stopped matching comparisons.

## Wrong-candidate

A future produce may want to REQUIRE parens around bool compares; until then
the scan-skip is the rule.

## Pin

110_032 (module bare-expr 6-field tor with a `<=` comparison — red before,
green after) and the whole comparison corpus (020_*, 320_*, 100_085).