---
type: belief
id: frag-diagnostic-stage-follows-pass-home
provenance: surfaced building the [with] KORU140 collision wall — 641_013 was mispinned FRONTEND_COMPILE_ERROR, cost an hour before the stage mechanics were understood (2026-07-14)
ts: 2026-07-14
---

# A diagnostic's EXPECT stage follows where its detecting pass lives (belief)

The EXPECT tokens are not a taxonomy of how "frontend-ish" an error *feels* —
they name the pipeline stage at which the failure actually surfaces, and that
stage is fixed by which pass catches it:

- **`FRONTEND_COMPILE_ERROR` = koruc Pass-1 (`koruc <in> -o backend.zig`) exits
  nonzero.** Pass-1 is **Stage-A only**: it parses, runs the *Zig* checkers
  directly (shape_checker, flow_checker, phantom_semantic_checker), and emits
  `backend.zig`. It does NOT run the metacircular pipeline. So a diagnostic can
  be a FRONTEND_COMPILE_ERROR *only if a Stage-A Zig checker emits it* — which is
  why KORU105 (flow_checker) fires there and 210_141 pins it that way.
- **`BACKEND_COMPILE_ERROR` / `BACKEND_RUNTIME_ERROR` = the metacircular pipeline
  fails.** The passes in `koru_std/compiler.kz` (frontend + analysis:
  check-structure, auto-discharge, check-phantom-semantic, resolve-with-scopes,
  …) run at **Stage C** — only when the built `backend` binary executes. Their
  rejections surface at backend-build or backend-exec, never at Pass-1. This is
  why auto-discharge and phantom rejections pin BACKEND_* (330_053/064) even
  though they are semantically "analysis."

The load-bearing consequence: **a feature implemented as a metacircular pass
cannot be pinned FRONTEND_COMPILE_ERROR, no matter how frontend-shaped its error
reads.** `[with]` ambiguity (KORU140) is a name-resolution error — feels like the
purest frontend concern — but `[with]` resolution lives in the metacircular
compiler by ruling (canonicalize, the Stage-A resolver, was off-limits; see
[[frag-parser-library-peg-on-two-glyphs]] for the sibling `[with]` doctrine). So
its wall fires at backend-exec and 641_013 pins BACKEND_RUNTIME_ERROR.

Corollary, made explicit here because it was previously dead: a diagnostic a
metacircular *frontend* pass records into `ctx.errors` has no `.failed` arm of
its own to halt on — check-structure (first analysis pass) surfaces those and
fails there. Before this, `report-error` populated `ctx.errors` and nothing ever
read it.

The pit this belief walls: reaching for FRONTEND_COMPILE_ERROR because the error
is "obviously a compile-time name thing," then chasing why koruc Pass-1 keeps
succeeding. It succeeds because Pass-1 never ran the pass that catches it. Pin to
the stage the *pass* lives in, not the stage the *concept* feels like.

Open: whether we ever want to lift metacircular-analysis diagnostics up to a
Stage-A koruc surface (a true frontend error for the user) is a separate, larger
program — deliberately NOT done for `[with]` (it would undo the steering that put
resolution in the metacircular compiler).
