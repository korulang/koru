---
type: frag
id: frag-the-discovery-pipeline-decomposes-at-tor-boundaries
provenance: rational-kit session 2026-11-26 (kernel + residual-sys + cert-of-kernel)
ts: 2026-11-26
---

# The discovery pipeline decomposes at tor boundaries

Prior belief: `derive-ode` was a monolith — series expansion, residual
system, exact ℚ null-solve, held-out witness, and certificate emit all
fused inside one private proc, so a `.k` program could invoke discovery
but never compose it. That is no longer true.

The split lands at the canon boundary:

- `linalg:kernel { a } -> exact | singular | bad-dims` — RREF null-vector
  over ℚ (last free column = 1); `|singular` names the trivial kernel.
- `supgen:residual-sys { a, order, deg } -> exact {z, w} | ...` — emits
  the (M+V)×U residual block as TWO canon `mat:v1` strings: z = the M
  solve rows, w = the V held-out witness rows.
- `supgen:cert-of-kernel { x, order, deg, verified }` — integerizes a
  kernel vector and emits the certificate; `verified` is caller-supplied
  provenance, honest because the caller computed the witness row count.

The `.k` composition is `residual-sys -> ingest-owned -> parse ->
kernel -> dup -> mul -> is-zero -> render -> cert-of-kernel`. sym cannot
`~import` linalg (cycle: linalg -> rational -> sym) — so **the canon
string is the data interface**, carried through `ingest`/`parse` custody.

The load-bearing property: **composed ≡ internal by construction**.
`derive-ode` and the public tors share `seriesDerivs`/`residualBlock`/
`certEmit` — one implementation, two entry surfaces. 615_090 pins the
fib-GF certificate emitted by the composed path byte-identical to
`derive-ode` output, and √(1+x) through the same composition.

This is the shape "prove theorems" takes in this tower: a theorem is a
tor that emits a certificate, and the certificate's authority comes from
a witness the program itself computed — `mul(W,x)` + `is-zero`, not a
trusted premise.

Measured nuance found en route: `string<std/io:!allocated>` on an input
param consumes a foreign obligation — the bang spells inside the
namespaced tag (bare `<!tag>` is always module-local;
`string<mod:tag!>` on input is refused as an issue, KORU033).
`ingest-owned` therefore consumes `std.io:allocated` directly — no copy.

Evolved 2026-11-26 (same session, the inverse direction): the pipeline
runs BOTH ways. `residual-sys-of-terms { terms, order, deg }` takes
`terms=L:c0,c1,...` — the format `series` itself emits — and builds the
residual block from coefficients alone: the residual machinery never
needed the expression, only `fder`, and `fder` only needs the array.
`series → residual-sys-of-terms → kernel → witness → cert-of-kernel`
discovers the law FROM NUMBERS and emits the identical certificate
(615_091: fib coefficients → the (2,2) cert, byte-identical to
derive-ode on the generating function). The honest bound is named:
`| too-few-terms` when fewer than U+K+21 coefficients arrive — the
held-out witness rows must be real data, not zero-padded invention.
What this is NOT: ODE → closed form — inverting a certificate back to
`x/(1-x-x²)` is the solver's lane (kovacic/rsum), a separate build.
