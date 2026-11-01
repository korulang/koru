---
type: belief
id: frag-authored-math-spells-expr-not-s
provenance: sym:lit surface ruling, 2026-10-31 — Lars ruled `s: string` for
  authored math is not healthy; `expr: Expression` is the spelling for
  expression-bearing params. Evolved 2026-11-01: authored code in a foreign
  grammar spells `source: Source` as a trailing block — `lit { π+π }`,
  `rel-law(name: cos, reg: r3) { -1e0*g(sin) }` — mirroring kernel shape/init.
ts: 2026-11-01
---

# Authored code never travels in quotes (belief)

A parameter that takes *the author's own code or math* never spells `s:
string` — quoted text the compiler can't read is authored structure
smuggled through the string lane. Two honest spellings, by grammar:

- **Koru-side authored values** → `expr: Expression` — a bare identifier or
  expression at the callsite (`rel-law(name: cos, ...)`,
  `rel-seed(name: sin, ...)`, `push(x)`); the compiler sees structure, the
  proc receives text at runtime.
- **Foreign-grammar code** → `source: Source` as a trailing block —
  `std/sym:lit { inv((1e0+(-1e0*x))) }`, `std/quantity:lit { 5+-0.5 m/s }`,
  `rel-derive(reg: r4) { g(sin)*g(sin)+g(cos)*g(cos) }`. The block carries
  opaque text the proc's own parser reads (`source.text`) — the same
  contract kernel's `shape`/`init` use. No ceiling: the block's grammar
  never has to parse as a koru expression.

`source:` reaches runtime tors — the call emits `__koru_ast.Source{ .text
}` into the Input struct and the proc binds `const source = input.source`;
it is not comptime-only (measured: `615_0*` lane, 41/41 green on
`source:`-spelled `lit`/`rel-*`).

`s:` survives where text genuinely *is* the input — the external-text lane.
`ingest`/`parse` keep `s:` because outside data arriving tainted is their
whole contract; the taint boundary is text-shaped on purpose.

Line: authored code → `expr:` or `source:`-block; outside text → `s:` under
an external mark. Remaining borderline: `quantity:lit-sym`'s `unit`/`unc`/
`cov` field strings — multi-field surface wants a Lars spelling, not a
guess.
