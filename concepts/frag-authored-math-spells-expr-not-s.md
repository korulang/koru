---
type: belief
id: frag-authored-math-spells-expr-not-s
provenance: sym:lit surface ruling, 2026-10-31 — Lars ruled `s: string` for
  authored math is not healthy; `expr: Expression` is the spelling for
  expression-bearing params (array:sort, constructor:push, compiler:use)
ts: 2026-10-31
---

# Authored math spells `expr:`, not `s:` (belief)

A parameter that takes *the author's own math* spells `expr: Expression` —
the callsite writes expression syntax (`sym:lit(expr: π+π)`), the compiler
parses it as an expression, and the proc receives the text at runtime. A
`s: string` param on such a surface is stringly-typed: quoted text the
compiler can't read, authored math smuggled through the string lane.

`s:` survives where text genuinely *is* the input — the external-text lane.
`std/sym:ingest`/`std/sym:parse` keep `s:` because outside data arriving
tainted (`<sexpr-external!>` then discharged to `<sexpr!>`) is their whole
contract; the taint boundary is text-shaped on purpose.

Line: authored expression → `expr: Expression`; outside text → `s:` under
an external mark. Open question: whether `expr:`-bearing params should
also admit a checked canonicalization step beyond text passthrough.
