---
type: belief
id: frag-arguments-are-atoms
provenance: introduced by d5ae078b — test(pin): nested call in argument position is ILLEGAL — 320_127 flips to MUST_FAIL (Lars-ruled)
ts: 2026-07-05
---

# Calls are not expressions — anywhere (belief)

Expressions are pure value computations over atoms: literals, bound names,
field paths, operators, builtins. A call inside ANY expression position is
**illegal Koru**. Ruled by Lars 2026-07-05 (re-affirming a months-old core
rule), with the reason stated in full: **purity reasoning is only sound if
expressions are closed under purity by construction** — the phantom
checker's obligation accounting, escape-driven stack allocation (obligation
= lifetime proof), the purity three-layer model, and comptime evaluation
all treat expressions as opaque effect-free computation. A call hiding in
an expression anywhere makes every one of those analyses reason about a
fiction. So the wall must be IRON CLAD across the whole toolchain.

Composition lives in the **flow**, not in expression trees. An inner result
crosses into an outer call through an explicit bind:

    r1(x: 5): a |> r1(x: a)

This is why the entire corpus — every regression test, every benchmark
kernel, including the tree-recursion shapes (hanoi's inner recursive result
feeding an outer call) — is written bind-first: dataflow stays visible in
the chain, where the language's checkers and the reader can see it. Nesting
calls in arguments would smuggle dataflow out of the flow.

**The wall is BUILT (2026-07-05, same session as the ruling): KORU104, the
expression-admission wall**, in flow_checker's frontend pass (Stage A,
pre-transform — every text it judges is user-authored). One predicate
(`expression_parser.textContainsCall`: structural parse + string-aware
raw-scan fallback), one walk over every expression carrier reachable from
a flow: invocation arguments (which covers if-conditions and for-bounds —
both parse as invocation args), `when` clauses, produce (`->`) bodies
(including `immediate_impl` items, the bare-return impl kind), branch-
constructor and captured fields, label-jump args, body-position
expressions. Diagnostic: "nested call in <surface> — calls are not
expressions; use event chaining: bind the result first."

The wall does not judge the QUOTING surfaces: Source-typed args (opaque
code blocks) and declared-`Expression` params (comptime capture — the text
is data handed to a transform proc, never executed in the flow; 210_036/
210_046 pin that verbatim capture). Those are the metaprogramming escape
hatch, exempt by design, keyed off the declared param type — never off
the text's shape.

The five formerly-open surfaces are pinned as permanent MUST_FAIL guards,
all green against the wall: 320_127 (args), 320_128 (if-condition),
320_129 (produce), 320_130 (captured — the PARSE003 branch-ctor guard
never covered captured fields), 320_131 (for-bound). The pre-existing
guards remain as parse-time belts: PARSE003 branch ctors (now sharing the
one predicate) and std/io interpolations.

History of the map (probed 2026-07-05, seven probes, all SHOWN): 2 guarded
per-surface, 5 open — the architectural defect was per-surface hand-wired
guards instead of one wall, so every new expression position defaulted to
OPEN. In all seven probed shapes the leak died at Stage D only by luck of
syntax and name-mangling (no silent-success path found, but no guarantee
either). Open edges: `.k` body-expression parsing (expression-layer A)
must consult the same predicate when it lands; a transform declaring
whether its Source payload is expression-shaped (capture/captured are
name-cased in the wall today) is an undesigned contract.

Displaces the belief carried in pin commit 032b0e69, which encoded the
argument-position shape as legal-but-mislowered ("fix = make the emitter
lower it"). It was never a lowering gap; it is an illegal construct
missing its wall — and the wall was missing on five surfaces, not one.
