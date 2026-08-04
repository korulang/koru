---
type: belief
id: frag-destructure-on-bind
provenance: built 2026-07-12 — Lars ruled it in for parity ("probably should for parity... an EXCELLENT feature and syntax")
ts: 2026-07-12
---

# Destructure-on-bind — the bind-position twin of branch-payload destructure (belief)

A bare-return record can be shape-destructured at the bind position, exactly as
a branch payload is: `~locate(): { pos: { x, y }, label } |> …`. Lars ruled it
in 2026-07-12 for parity — branch-payload destructure (`| found { name, age } |>`,
020_016) is a green, established feature, so its bind-position twin should exist.
It is the natural consumer of a `-> { record }` bare return, and the migration
target for the old `| at { … } |>` branch form on a now-bare-return tor
(020_017).

Semantics mirror the branch form field-for-field, including the KORU100 rule
that every NAMED field must be used (or `_` to discard) — 020_019 pins the
`unused binding 'age'` rejection.

Implementation is the "thread the new AST field through every layer" pattern
([[koru_new_ast_field_threading]]), reusing the existing destructure machinery
rather than inventing lowering:
- **AST**: `Invocation.return_destructure: []const DestructureField` (bind-site
  twin of `Continuation.destructure`).
- **Parser**: in the `: bind` scan, a `{` after the colon parses via the SAME
  `parseDestructureFields`; the return is bound to a synthetic temp
  (`__ret_destr_N`) and `return_destructure` carries the fields.
- **Emitter** (emitInvocation): after the temp bind, `emitDestructureConsts`
  emits `const x = __ret_destr_N.pos.x; …` — the same helper the branch form uses.
- **flow_checker**: a bind-position usage check that searches the DOWNSTREAM
  continuations only — the declaration lives on the same node whose result flows
  on, so searching the declaring node would count the declaration as a use (a
  self-reference false positive that let an unused field slip through).
- **serializer / cloneInvocation / ast_printer**: threaded so the field survives
  the Stage-A→C round-trip, every transform clone, and `--print` round-trip. The
  printer renders `: { … }`, NOT the synthetic `__ret_destr_N` temp.

Nested destructure (`pos: { x, y }`) works via `DestructureField.sub` — no extra
work, the recursion in `parseDestructureFields`/`emitDestructureConsts` already
handles depth. Pins green: 020_017 (nested-into-host), 213/214 (chained binds,
which were NOT destructure — the migration classifier over-matched on `{{ }}`
template braces).
