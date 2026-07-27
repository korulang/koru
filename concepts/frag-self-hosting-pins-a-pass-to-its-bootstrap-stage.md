---
type: belief
id: frag-self-hosting-pins-a-pass-to-its-bootstrap-stage
provenance: measured 2026-07-28 while trying to move the AST desugars out of koruc and into the backend's elaborate segment
ts: 2026-07-28
---

# A pass implementing a feature that `koru_std/compiler.kz` itself uses can be ADDED elsewhere, never MOVED out of `koruc` (belief)

`koru_std/compiler.kz` is Koru. `koruc` compiles it. So every language feature
the compiler's own source *uses* must already work in `koruc` — before the
self-hosted pipeline exists to provide it.

That makes the set of passes living in `koruc` not purely a design choice. Part
of it is forced, and which part is decided by what `compiler.kz` happens to be
written in.

## What forced the belief

`~elaborate`'s own body is a point-free chain — `resolve-with-scopes() |>
desugar-chains() |> …` with empty parentheses, relying on the type thread to
fill each stage's `ctx`. Moving the desugars into that segment removed, from
`koruc`, the pass that fills those arguments. The generated backend came out as
`resolve_with_scopes_event.handler(.{ })` and failed to compile: the pipeline
could no longer build the pipeline.

The dependency is circular by construction and cannot be ordered away.

## The consequence for "where should this pass live?"

The honest question is never *move or not*. It is:

- Does `compiler.kz` use this feature? If yes, `koruc` keeps its copy — that
  copy is the bootstrap, and it is not optional.
- Does the pass need information `koruc` does not have? If yes, a second run
  belongs later, where that information exists.

Both can be true at once, and when they are, running the pass twice is the
correct answer rather than a hedge. The two runs are not redundant: the first is
necessarily partial, the second completes it once more is known. The pass must
be idempotent for this to hold, which is a property to verify, not assume.

## What this does not say

It is not an argument for keeping work in the frontend. Passes that
`compiler.kz` does not depend on are free to move, and the stated direction —
compilation belongs in the backend — is unaffected. This only says the
bootstrap set is discovered, not chosen, and that discovering it is a
measurement (build the compiler and see), never a reading.

Related: [[frag-a-stale-binary-lies-like-a-compiler-bug]] — the other way the
two halves of Koru's clock draw blood.
