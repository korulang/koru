---
type: belief
id: frag-runtime-build-graph-duplicates-build-zig
provenance: found while taking 440_RESOURCE_BRIDGE from red to green — the cross-session discharge pin was failing partly on a missing `struct_literal` module that build.zig had wired years-of-commits ago
ts: 2026-07-25
---

# The runtime's build graph is a hand-copy of `build.zig`, and it drifts silently

`koru_std/interpreter.kz` opens with a `~std/build:requires { ... }` block that
hand-constructs the Zig module graph — `errors`, `ast`, `lexer`, `type_registry`,
`expression_parser`, `parser`, `flow_parser` and friends — rooted at the
*installed* compiler (`REL_TO_ROOT = "/usr/local/lib/koru"`). Any program that
imports `std/runtime` or `std/interpreter` gets that graph, because it needs a
real parser at runtime.

That graph is a **second copy** of the wiring in `build.zig`, and the two have no
mechanical relationship. When a new module joins `src/parser.zig`'s imports,
`build.zig` gets updated immediately — the compiler will not build otherwise, so
the feedback is instant. The `requires` block gets nothing, because nothing
compiles it until some test actually imports `std/runtime`. The interpreter
clusters were parked, so nothing did, for a long time.

The failure lands far from the cause: a Stage-D Zig error naming a module that
"is not available within module 'koru_parser'", inside a `zig build-exe` command
line, in a test whose subject is resource bridging. Nothing points at the
`requires` block.

The invariant, until the duplication is gone: **the `requires` block's
`parser_module` imports must be a superset of `src/parser.zig`'s `@import`s.**
Same for every other module it mirrors. When touching either side, diff them.

Open, and the real fix: there should be one graph, not two — either the
`requires` block is generated from the same declaration `build.zig` uses, or the
runtime's parser dependency is expressed so the build system derives it. A
duplicated graph that only one side exercises is a trap that resets every time
the compiler's own module list moves.

Related: [[frag-compiler-flags-baked-into-backend]] (the other place the
metacircular pipeline's two halves disagree about what is baked and what is
resolved).
