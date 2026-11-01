---
type: belief
id: frag-a-trusted-string-field-is-an-authored-expression-in-disguise
provenance: introduced by the lit s:-drop commit on quantity-numbers
ts: 2026-11-01
---

# A trusted string field on an authored-lane tor is a second spelling, not a second lane (belief)

`std/sym:lit` declared `s: ?string, expr: ?Expression` for one release. Every
caller of `s:` spelled a string literal — measured: 80 sites, 12 test files,
zero dynamic bindings — and a string literal is already an Expression
spelling the compiler captures verbatim. `s:` was therefore not an input
lane; it was the authored lane wearing quote marks, plus a quiet trust
escape hatch: the field would also have accepted runtime-computed text and
called it `lit`, laundering provenance the ingest/parse boundary exists to
name.

The ruling: **one tor holds one lane.** `lit` keeps `expr: Expression` —
authored math, captured as source, `bad` on malformed grammar. Runtime text
goes `std/sym:ingest` (tainted, `string<sexpr-external!>`) then
`std/sym:parse` (the declared discharge), never `lit`. An unlabeled string
literal still lands on `expr` — verbatim capture keeps the quotes — so the
proc unquotes it; that is grammar-legal sugar for the authored lane, not a
reopened wire lane.

The check before deleting a "redundant" field is the provenance question,
not the type question: does anything that can only arrive at runtime need
this spelling? If yes it is not redundant, it is misnamed — it wants the
ingest boundary. If no, it was never a lane.

**2026-11-01 — the unit DSL was not an exception.** `std/quantity:lit`
looked like the case where `s:` was honest: `"5.0±0.2 m·s⁻¹"` is not a Koru
expression. But that was the *spelling*, not the content. Magnitude, unit
product, uncertainty and covariance tag all have expression-shaped
spellings — `lit(5.0*m/s, unc: 0.2)`, `lit(2*m, unc: 0.1, cov: bias)` — and
the old text spelling survives exactly where it belongs: `ingest`/`parse`
for wire text. A DSL that resists `expr:` is first a question of whether its
glyphs were chosen for the page or for the parser; only the residue that
genuinely is not expression-shaped (a bare `-` cov tag on `lit-sym`) keeps a
string field. The cost is stated: one magnitude term per literal —
`lit(2*π*m)` refuses by name rather than folding decimals quantity cannot
multiply.

Pairs with [[frag-expression-source-are-strings-not-comptime]] (capture is
representation, not timing — `expr:` arriving as text is why the runtime
re-parse is honest) and [[frag-taint-is-per-value-signal-is-per-stream]]
(provenance rides the value; `lit` must not be a quieter way in than
`ingest`).
