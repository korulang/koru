---
type: belief
id: frag-deferral-does-not-survive-transform-consumption
provenance: 2026-11-21 — koru100-false-unused-sweep-boundary: a destructure bind read inside a transplanted std/store:query sweep body drew a lying KORU100 in `.all` mode
ts: 2026-11-21
---

# Deferral is a property of the pre-transform tree — consumption erases it (belief)

A binding-usage check split frontend/`all` assumes the `deferred` signal
means the same thing computed on either tree. It does not. Deferral is
derived from the node a continuation hangs off — `[transform]` or
`[template]` resolution — and consumption removes that node. Post-transform,
`isDeferredBindingInvocation` reads false not because the binding became
checkable but because the evidence was consumed with the subtree.

The arm-binding check survives this by accident of polarity: `.all` skips
non-deferred, so an erased marker lands on skip. A check that instead
verifies deferred bindings in `.all` mode scans a subtree the transform
already emptied — the use moved into a synthesized flow the subtree walk
cannot reach — and reports "unused" for a binding that is used. The
sweep-boundary destructure was exactly that shape.

The ruling this forces: **a deferred check must pick ONE tree to judge.**
Frontend owns the unexpanded AST, where uses are still text; `.all` owns
only what frontend could not see AND the transform left attributable. When
a transform consumes the use site, neither tree can honestly answer — the
boundary itself must refuse or carry the binding (the sweep's `?` capture
wall), not the usage checker.

Open: the same erasure applies to any `.all`-mode check that re-derives a
frontend-time property from node resolution — return destructures,
obligation carries, anything else keyed on `isDeferredBindingInvocation`.
Related: [[frag-the-transformed-mark-is-per-node-not-per-subtree]] (the
sibling failure — a checker pruning on a mark the transform left per-node),
[[frag-a-refusal-invalidates-the-next-checks-facts]] (staged verdicts read
facts a later stage already spent).
