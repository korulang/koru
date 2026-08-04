---
type: belief
id: frag-stripe-rule-scheduling
provenance: ruled by Lars 2026-07-18 (naming as cross-cutting annotation; depends_on over rank integers; defined generated-code order); built same day as the plural-stripe rung; pins 690_038/039/040; proven end-to-end by koru-libs raylib bounce.k
ts: 2026-07-18
---

# Standing rules are named with [name(x)] and ordered by [depends_on(x)]; stripe fires them in topo order (belief)

Plural `stripe(store)` runs the store's standing compiled rules across the
corpus once, now — O13's scan-driven firing mode, landed as a per-store
`__store_stripe_<s>` unit calling each rule's qsweep. Scheduling vocabulary:

- `[name(x)]` on the attach flow names the rule. Bare identifiers, not
  strings — names live in identifier space ([[frag-store-verb-placement]]'s
  sibling ruling made bare canonical for depends_on corpus-wide). Names are
  module-namespaced exactly like phantom states: bare binds in the declaring
  module, cross-module references qualify `mod:name`, bare-outside is a
  teaching error. Duplicate name within a module is rejected.
- `[depends_on(a, b)]` declares edges. The stripe fires rules in TOPO order
  of the declared DAG; a cycle is a located comptime error naming its
  members. Rules with no declared edges are contractually UNORDERED
  relative to each other — the fusion license: O13's one-fused-pass prize
  requires the scheduler's freedom wherever no edge binds it.
- Naming is CROSS-CUTTING by design (Lars): any flow can carry [name(x)]
  syntactically today; the store scheduler is the first consumer. Future
  consumers: trellis path addressing, variant selection (pinpointing
  subtrees for MLIR-class lowering), diagnostics ("in rule movement").

This closes [[frag-store-verb-placement]]'s plural-stripe Open item. The
end-to-end proof is koru-libs raylib/tests/bounce.k: movement as a named
rule, report depends_on(movement), one stripe per ! frame body — exact
deterministic positions over 4 frames.

## Open

- Rule CONTEXT: a per-entity draw rule needs the frame borrow inside its
  body; the ambient-context wall (690_006) correctly forbids capture.
  Parameterized stripe / declared rule params is the next design step —
  the remaining half of store-as-game-state.
- Multi-field stored-through-cursor is red (690_038): the stored transform
  mis-parses the indexed head with >1 field. Chained single-field writes
  are the legal form (chain-envelope: one atomic unit).
- Tor-driven firing of plural query rules (the write-mode of O13's two
  modes) is deliberately unbuilt this rung; its entry ticket is closing
  the T2 reactive-edge cycle graph over ALL edges.
