---
type: belief
id: frag-compiler-flags-baked-into-backend
provenance: floated 2026-07-14 while adding the --release gate (feat(prototype)); Lars parked it as low-priority, pin the observation in prose
ts: 2026-07-14
---

# Compiler flags/env are BAKED into the backend; the AST is runtime data (belief)

An asymmetry in the metacircular pipeline, worth knowing before anyone "optimizes"
flag handling or debugs a surprise backend rebuild:

- **The AST is runtime data.** koruc writes it to `program.ast.json` and the Stage-C
  backend deserializes it at runtime (`src/main.zig:274`; the backend-cache comment
  at `scripts/regression_lib.sh:23` says the program AST "is now a runtime input
  (program.ast.json) and is deliberately excluded" from the cache key). So the same
  backend binary serves any program.
- **Flags + env are baked in as code.** `generateCompilerEnvCode` (`src/main.zig:196`)
  emits a per-invocation `compiler_env.zig` with the flags as compile-time constants,
  and `hasFlag` is `comptime` with an `inline for` (`src/main.zig:220-229`). Header it
  writes: *"Flags + env vars baked from the CLI invocation"* (`src/main.zig:201`). The
  flags are compiled into the backend at Stage B.

## The consequence, and what is NOT wrong

Every distinct flag-set forces a **Stage-B backend recompile** — a new
`compiler_env.zig` is a new source input. So `--release` vs a dev build of the same
program compile two different backends; `--panic-branches=strict` likewise.

This is **not** a cache-correctness bug — the tempting worry ("a flag change reuses a
stale backend") does not hold. The backend-binary cache key hashes `compiler_env.zig`
itself (`scripts/regression_lib.sh:30-34`), so a flag change yields a different key and
a different binary; Zig's own Stage-B cache recompiles when the file changes. Both
layers are gated. The real cost is only the recompile, never a wrong result.

## The open tradeoff (why it is the way it is, and why it's parked)

Baking flags as `comptime` lets the backend **dead-strip** flag-gated code paths at
compile time — zero runtime cost for a disabled flag. Moving flags to a runtime data
file (symmetric with `program.ast.json`, so a flag flip would NOT rebuild the backend)
would turn `hasFlag` into a runtime check and lose that elimination. The AST cannot be
comptime (it is inherently per-program data); flags plausibly were made comptime on
purpose for the dead-strip.

So this is a comptime-elimination-vs-recompile-avoidance tradeoff, not an oversight —
and Lars parked it as low-priority (2026-07-14): the recompile cost is tolerable today,
and the correctness is sound. Revisit only if backend-rebuild churn from flag changes
becomes a real drag; if so, the move is a data-file for flags, weighed against losing
comptime flag dead-stripping. The `--release` gate ([[frag-prototype-mode-panic-holes]])
reads `hasFlag("release")` at Stage C under this baked-in scheme and is unaffected
either way.
