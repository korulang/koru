---
type: belief
id: frag-peel-pass-eligibility-is-a-pinned-boundary
provenance: recwar leg — arbiter commission t5w, regression pin suite for
the bounded recursive-unroll ("peel") pass, challenge 035 coverage
expansion; pins landed before the pass (t6h) exists
ts: 2026-11-25
---

# Peel-pass eligibility is a pinned boundary, not a tuning knob

The bounded recursive-unroll pass's v1 contract is fixed by regression
pins *before* the pass lands: eligible = direct self-recursion with one
designated param decreasing by a positive constant on EVERY self-call
site and a body drawn only from {if-dispatch, self-call binds,
expression/return leaves}; everything else refuses *silently* — no
diagnostic, no transform, emitted shape unchanged. The suite pins the
boundary by emitted-structure census (residual `X_event.handler(` site
counts = s^(D+1) + external, substituted-guard fingerprints), not by
error text, because refusal is defined as absence-of-transform.

Measured rulings the pins encode:

- **v1 eligible set is exactly {fib, hanoi, pascal}.** Each excluded
  kernel fails for a named reason the suite asserts separately:
  ackermann (no param decreases on all 3 sites — lexicographic (m,n)
  termination is invisible to a single-param witness, and it is hanoi's
  structural twin, which is why it is the control), tak (permuted args +
  a dependent call with no affine decrement, s=4 would explode G(D)),
  coins (asymmetric data-dependent decrement + foreign coin() call — v2
  candidate only), mutual (not direct self-recursion; already ~0.24
  ns/call under LLVM).
- **Effects refuse on shape, not on an effect flag.** io print, store
  writes, for-loops, and arm-nested self-calls each leave the allowed
  node set; the pass never needs to name the effect to decline it.
- **Depth is part of the contract.** D=2 default → s^(D+1)=8 residual
  sites at s=2; the ==9 census (8+1 external) is the pin. A depth-default
  change is a deliberate pin update, not a silent drift.

Resolved (recwar/unroll-land): hanoi's dependent-arg shape takes
*precedence*, not composition — the pass writes the unrolled machine
into `flow.inline_body` as a `//@koru:inline_stmt` body, and the
emitter lowers pass-set machines (detected by the `__koru_unroll_`
label, never a bare inline_body check — templates and pre-transforms
share that slot) ahead of flat-segment lowering, skipping the
self-loop wrap/epilogue whose `continue`/`unreachable` have no target
in straight-line code. The emitted `__koru_seg_*` decls go dead and
Zig never analyzes them. The boundary held: all 12 pins green on
first landing, hanoi's `acc: h + 1` sibling-fed arg surviving
substitution exactly as pinned.

Boundary refinement (fix commit): branching factor s must be >=2 —
s=1 linear recursion refused because bodyCopies divides by (s-1) and
v1's win is the branching kernels; the full board caught four
backend-exec crashes (320_096/320_122/810_101/810_102) on s=1 shapes
the pin suite never exercised. Ceremony worked as designed.

Still open: a capture-mutation pin is blocked on language surface
(`! as` cannot head an impl flow); it joins the suite when that
surface exists. The pathsEqual helper twin (ast_transform vs
emitter_helpers.sameDottedPath) is documented fold material — folding
needs an ast_transform→ast_functional backend-module edge and
koru_std/compiler.kz is line-pinned.
