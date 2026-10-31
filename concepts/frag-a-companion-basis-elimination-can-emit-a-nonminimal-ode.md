---
type: frag
id: a-companion-basis-elimination-can-emit-a-nonminimal-ode
provenance: koru-quantity / sym.certcomp certClosure, sym.certgen cert-of
ts: 2026-11-01
tags: [koru, holonomic, certificates, semantics]
---

The closure machinery (`certClosure` — the HolonomicClosure port) finds
linear dependencies among derivative VECTORS in `Q(x)^dim`. When the
input generators are themselves dependent over `Q(x)` — the companion
basis has a kernel — a true function-level dependency may not appear as
a vector-level dependency, because distinct vectors can denote the same
function.

Measured: `cert-of(1 - x)` via `sum(const, -x)` emitted `f'' = 0`
(order 2) although `f + (x-1)f' = 0` (order 1) holds — the kernel
direction `(x, 1)` (`x*1 + 1*(-x) = 0`) hides the tighter relation.
The emitted cert is always SOUND (a vector dependency is a real
dependency); it is merely not minimal.

Consequence for consumers: rules keyed on certificate order — e.g.
`inv` requiring an order-1 inner cert — can over-refuse on inputs that
mathematically qualify. Where a direct construction exists for a
grammar shape (polynomial inv `p g' + p' g = 0`, polynomial sqrt
`2p g' - p' g = 0`), take it BEFORE consulting the closure-derived
inner cert — `cert-of`'s `.inv` arm does exactly this.

Open question: whether a minimality pass (dividing out known kernel
directions, or verifying a lower-order candidate against the series
oracle) belongs in the cert layer at all, or whether minimality is a
discovery-lane concern (`derive-ode` already finds the minimal one
within its bounds).
