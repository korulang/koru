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
