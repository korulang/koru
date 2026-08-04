---
type: belief
id: frag-template-expand-freezes-before-create
provenance: session 2026-07-23 (Lars + Grok) — todo_tui selection cursor; 690_074
ts: 2026-07-23
tags: [toolchain, store, template, lowering, timing]
---

# Template expand freezes Expression text before store:create can rewrite it

`|template|zig` procs (`if`, `for`, …) bake Expression arg text into
`Flow`/`Invocation.inline_body` at expand time. `std/store:new`'s cell-path
rewrite (`store.` → `__koru_store_<store>.`) historically only touched
transplanted watch/interceptor bodies and live Expression args. That is
**too late** for anything already frozen into `inline_body` — the emitter
reads the freeze, Zig sees undeclared `ui`, while the same `ui.sel` in a
later Expression (print interp, stored RHS) rewrites fine.

## The companion Zig trap

Whole-program Walk must mutate the live AST. `switch (n.*) { .invocation => |*inv| … }`
captures a **temporary** Invocation; assigning `inv.inline_body = …` is a
no-op on the real node. Arg rewrites still "worked" because `inv.args` is a
slice aliasing heap — that asymmetry hid the bug. Same family as Walk's
`|*f|` on switched Flow copies: mutate via `&pi.flow` / `n.invocation`, never
pointer-captures of switched union values.

## What this pins

Store create must Walk `inline_body` (and `inline_code`) after expands, and
must not use temporary-capturing switches when writing those fields. Pin
`690_074`. The belief is the *ordering* and the *mutation contract* — not the
rewrite regex itself.
