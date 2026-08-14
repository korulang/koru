---
type: belief
id: frag-a-kernel-aggregate-needs-its-own-exit
provenance: session 2026-08-14 — std/kernel:reduce (aggregates out of a compute scope)
ts: 2026-08-14
tags: [koru, kernel, transform, exit-branch]
---

# A kernel's scalar aggregate cannot ride the `computed` exit — it owns a branch (belief)

The kernel system looked like it had one result channel: results exit via
`| computed c |>`, and that branch is a **single-field identity** — payload
`{ __type_ref: []T }` — so `c[i]` resolves straight to element access (the
compiler treats a `__type_ref`-leading single-field branch as identity). A
scalar aggregate has nowhere to live in that shape. Slipping one in beside
`__type_ref` breaks the identity and with it `c[i]`; there is no clean
"computed plus a field" because the identity IS the array.

So a kernel that answers with a number instead of the array required its **own**
exit branch — a real struct payload carrying each accumulator by name.
`std/kernel:reduce` is the first op to own a non-computed exit (`| reduce r |>`),
and its exit exists because the identity branch could not be widened.

What would correct this belief: a future kernel result shape that carries array
and aggregates in one payload without breaking `c[i]` — either the identity rule
is relaxed (multi-field branches become legal as identity+scalars), or `computed`
stops being array-bound. Until a mechanism for that exists, an aggregate output
is a separate branch, always.

Corollary that stays true today and is the reason the change was cheap: the exit
is synthesized by the kernel transform as AST (branch + payload + return), so a
new exit is a transform change, not an emitter change.
