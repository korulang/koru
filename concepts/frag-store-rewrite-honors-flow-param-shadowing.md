---
type: belief
id: frag-store-rewrite-honors-flow-param-shadowing
provenance: 690_271 — a flow parameter named like a store was rewritten to the store cell; found live by kopium-headless/headed.k
ts: 2026-08-13
---

# The store-name rewrite must honor shadowing by a flow's own parameters, not only by continuation bindings (belief)

The resolution-order ruleset (690_086) says bindings win over module-local
stores: "bindings (innermost first) -> module-local stores -> `[global(name)]`
stores." 690_090 pinned that rule for a continuation's row binding (`! query
items` shadows a store named `items`). The store-name rewrite's bound-set
tracked those continuation bindings — but NOT a flow's own parameters. So
`~transit = reframe(goal, history)` with a store also named `history` rewrote
the punned argument to `__koru_store_history.__koru_value` — the store's
identity column — instead of leaving the parameter name for Zig to resolve. The
store won on a missing shadow, not on a rule.

The general shape keeps recurring: a **textual rewrite where the pass-order of
the scope it needs is not fully built/known**. The fix is to seed the walk's
bound-set with the implementing event's input-field names, so a parameter is a
binding exactly like a row binding, and a bare name that IS a parameter never
becomes a store reference.

What would correct this: the store rewrite being scope-aware structurally
(rather than accumulating shadow exceptions at the seed points), or the 
resolution-order rule being enforced somewhere that a missed shadow cannot
silently yield a wrong cell read.

Related: [[frag-inline-bind-pun-sources]] — punned arguments are where a bare
name meets a value, and the pun is where textual rewrites most often misfire.