---
type: belief
id: frag-a-chained-tor-produce-is-the-branch-return-value
provenance: 2026-08-13 — a plain Zig-backed Koru tor served as a router endpoint for the first time
ts: 2026-08-13
---

# A chained tor in produce position is the branch's return value, not a side effect

A router branch written `! [POST /x] req -> my-handler(req)` produces the
handler's response by *chaining* a user tor in bare-produce position. That
return was emitted as a side-effect discard (`_ = module.event.handler(...)`) by
continuation_codegen's simple-invocation path, so the response silently
vanished and the branch fell through. The parser normalizes a produce whose
payload is a call into a plain invocation node with **no produce mark** — only
the AST position (a root-level continuation with no nested continuations)
carries the should-return semantics.

The ruling: **a root-level leaf invocation is a bare produce — `return` it.**
Nested chain steps (inside `generateBranchSwitch` bodies) remain discards, so
`|> a |> b` semantics are untouched. The gate is the call depth (root vs nested),
not the type, because the codegen has no type information there.

The second half of the fix had to be the language, not the codegen: two
structurally identical anonymous `Response` structs are *nominally distinct* in
Zig, so returning one event's Output as another's failed to unify. Orisha now
names the response shape (`Response`) so any handler tor returns the SAME Zig
type as the abstract handler. **Naming a shared shape is what makes identical
Koru shapes unify across module boundaries.**

Open questions: whether the root-leaf-returns rule should apply beyond router
branches (any transform-rooted continuation with a leaf produce), and whether a
void-leaf root (`-> side-effect()`) should be a compile error rather than a
`return void`.