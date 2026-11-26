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
