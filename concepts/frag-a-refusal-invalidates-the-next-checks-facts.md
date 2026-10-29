---
type: belief
id: frag-a-refusal-invalidates-the-next-checks-facts
provenance: diagnostic-site audit round 2026-10-29 — shape_checker validateArmFire record-payload: `pair(wrong: 1)` produced "field 'a' missing" and "field 'b' missing" beside "no payload field 'wrong'" — the missing claims were speculation, since 'wrong' may be a misspelling of 'a'
ts: 2026-10-29
---

# Once a check refuses an input, a later check's claims about that input are speculation — gate it on the refusal (belief)

Diagnostic checks on the same input tend to run as independent passes: each
reads the args and reports what it sees. That independence is only honest while
the input is *resolvable*. Once an earlier check refuses — an arg names nothing
declared — every later check's verdict about the same input is built on sand:
the "missing field" it reports may be the very field the unknown arg meant to
name.

Measured in `shape_checker.validateArmFire`'s record-payload block: the
unknown-arg loop refused `pair(wrong: 1)` with KORU021 (naming the offender and
listing every declared field), then the missing-field loop asserted `a` missing
and `b` missing — two claims that are true only if `wrong` is not a typo of
either. One malformed call, three reports at one caret, two of them speculative.

The gate is one line: run the second check only when the first stayed clean.
`pair(a: 1)` still reports `b` missing; `pair(wrong: 1)` reports only the
KORU021 that already carries the field list. Sibling pattern, mirrored: the
obligation ledger's D5 — prose line numbers that restate a position the caret
already owns — same shape, different surface: **a diagnostic that asserts what
an upstream verdict made unknowable, or already said, is a pack report.**

The check to audit is not the message but the *guard*: does this site run
unconditionally on input a sibling may already have refuted? That is where
speculative diagnostics live.
