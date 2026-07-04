# Arguments are atoms — nested calls in argument position are illegal (belief)

A call's arguments are atoms: literals, bound names, field paths, plain
expressions over them. A call nested directly in argument position —
`r1(x: r1(x: 5))` — is **illegal Koru**. Ruled by Lars 2026-07-05, at full
force: the nested form goes stealth counter to core language design.

Composition lives in the **flow**, not in expression trees. An inner result
crosses into an outer call through an explicit bind:

    r1(x: 5): a |> r1(x: a)

This is why the entire corpus — every regression test, every benchmark
kernel, including the tree-recursion shapes (hanoi's inner recursive result
feeding an outer call) — is written bind-first: dataflow stays visible in
the chain, where the language's checkers and the reader can see it. Nesting
calls in arguments would smuggle dataflow out of the flow.

Compiler state vs. this belief: the wall doesn't exist yet. The compiler
accepts the nested form through Stage A/B and leaks the inner call's Koru
syntax verbatim into emitted Zig (raw Stage-D host error). Pinned as
MUST_FAIL 320_127 (wrong-error red): goes green when a koru-level rejection
lands — a diagnostic naming the nested call and hinting bind-first.

Displaces the belief carried in pin commit 032b0e69, which encoded the
shape as legal-but-mislowered ("fix = make the emitter lower it"). It was
never a lowering gap; it is an illegal construct missing its wall.
