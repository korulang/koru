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

Compiler state vs. this belief — the full surface map (probed 2026-07-05,
seven probes, all SHOWN):

- **Guarded (2):** branch-constructor fields (parser.zig PARSE003,
  structural containsFunctionCall + raw-scan fallback) and std/io
  interpolation expressions (io.kz @compileError). Both already say "use
  event chaining instead" — the wall's canonical hint.
- **Open (5):** invocation arguments (pin 320_127), if-conditions
  (320_128), produce `->` RHS (320_129), captured fields (320_130 — the
  PARSE003 guard does NOT cover captured), for range-bounds (320_131).
  All five accept the shape through Stage A/B and leak the call's Koru
  syntax verbatim into emitted Zig (raw Stage-D host error).

The architectural defect: the guard was built per-surface (hand-wired
twice) instead of as ONE expression-admission wall every surface passes
through — so each new expression position defaults to OPEN. The fix ruled
directionally: a single choke point ("an expression admits atoms,
operators, builtins; never a call"), koru-level diagnostic, event-chaining
hint, consulted by every expression consumer including future ones (`.k`
body-expression parsing, expression-layer A).

Latency of the danger, stated narrowly: in all seven probed shapes the
leak happens to die at Stage D because pasted Koru syntax / unmangled
event names don't resolve in emitted Zig. No silent-success path was
found — but that is luck of syntax and name-mangling, not a guarantee.

Displaces the belief carried in pin commit 032b0e69, which encoded the
argument-position shape as legal-but-mislowered ("fix = make the emitter
lower it"). It was never a lowering gap; it is an illegal construct
missing its wall — and the wall was missing on five surfaces, not one.
