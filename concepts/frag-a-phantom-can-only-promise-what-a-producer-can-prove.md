---
type: belief
id: frag-a-phantom-can-only-promise-what-a-producer-can-prove
provenance: session 2026-10-31 — rel-seed/rel-law/rel-derive over generator atoms, quantity-numbers arc
ts: 2026-10-31
tags: [koru, phantom, registry, sym, honesty-boundary]
---

# A phantom can only promise what a producer can prove — context-scoped validity lives at parse, not at the type

`string<sexpr!>` means "a `std/sym` op produced this text, therefore it is
canonical under the closed grammar." The phantom is a *producer-side proof*:
whoever mints the value discharges the obligation by construction.

Generator-atom expressions (`g(sin)*g(cos)` under a `rel:v1` registry) cannot
carry that phantom — not because they are less safe, but because *no producer
can prove their validity*. Whether `g(sin)` is well-formed depends on which
registry it is parsed against: the same text is valid under
`rel:v1;sin=...` and unknown under `rel:v1`. Validity is **context-scoped**,
and the context (the registry blob) only exists at the call site, not at any
producer.

So the honesty boundary moves: the type stays plain `string`, and the check
moves to the point where the context exists — `parseTreeG(alloc, s, greg)`,
which refuses `unknown-generator` by name. `<sexpr!>` values still can't leak
in (no rel surface accepts the phantom), and rel texts can't leak out into
`sym:add` (their parse refuses g-atoms under a null registry). Two disjoint
expression universes, each honest about where its validity lives.

The general rule: when designing a qualified type, ask *who can discharge
it*. If the honest answer is "only a call site carrying context X," the
phantom is the wrong mechanism — the right one is a parse-under-X gate with
named refusals. Phantom = producer proves; registry parse = context proves.
Both are honest; only one exists for context-dependent text.

Open: whether a first-class "registry-scoped sexpr" phantom parameter
(`string<sexpr@rel(reg)!>`-style) is worth a language feature — today the
boundary is spelled manually per tor.

EVOLVED 2026-11-01 (A0 numeric honesty): the same rule governs *how much*
a producer may promise, not only *whether*. `string<exact!>` on a `num`
means "canonical decimal, every digit produced by the stated contract."
Three producers were minting it for digits nobody had proved:

- `std/quantity` folded `π`/`φ`/`e` to a 36-digit literal with no `prec`
  anywhere in the call — a rounded value wearing the exact mark. The
  honest producer is the one that already exists: the symbolic magnitude
  lane. `lit(π*m)` now prints `π m`; digits appear only where a `prec` is
  spelled.
- The unit scale was an `f64` printed with `{d}` — a float carrying an
  integer exponent. It is now the exponent (`10^k`, canon `1e<k>`); a
  non-power-of-ten unit must refuse by name until rational scales exist.
- Sigma was computed at a hidden `prec: 15` in four places, and `div`/
  `sqrt` under it delivered `prec-1` or `prec+1` digits. The contract is
  now exact — `prec` significant digits, truncated — and sigma's precision
  is *derived* (widest input mantissa + 2 guard digits) and applied to
  every division and root on the uncertainty path, then to the final
  |mag|·σ_rel product via `num:trunc`.

The sharpened rule: a `prec` parameter is the producer's proof of
precision. A constant folded without one, a float formatted into a
decimal, or a precision literal buried inside the library is a promise
the producer cannot discharge — the phantom is lying by the width of the
hidden number. Push the precision to the call site or derive it from the
inputs; never bake it.

Open: `exact!` still names truncation, not correct rounding. A2 adds a
correctly-rounded `round` beside `trunc` and must decide whether the
mark splits (`exact!` vs `rounded!`) or the contract stays "exactly
`prec` digits under the stated rounding mode."
