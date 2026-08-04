---
type: belief
id: frag-payload-shape-vs-destructure-by-position
provenance: ruled 2026-07-15 (Lars) while nailing the branch-payload model for a formal spec — "destructuring never happens in an event DECLARATION, it happens at BINDING"
ts: 2026-07-15
---

# `{ … }` after a branch name means different things by POSITION, not shape

The same surface — a branch name followed by `{ … }` — is read two different
ways depending on **where** it appears. Position decides meaning; the shape of
the braces does not. This is the rule to get right first, because a formal spec
is built on it.

## Position 1 — tor DECLARATION: `{ … }` is a PAYLOAD SHAPE

`~event E {…} | ok { a: i32, b: u8 }` — the `{ … }` after `ok` declares the
branch's payload. It is a **shape declaration**:

- Type annotations are **required**, not forbidden: `{ a: i32, b: u8 }`.
- A **single field in braces** is illegal → collapse to identity: `| ok i32`
  (PARSE003, 210_063). `| ok { c: i32 }` must be `| ok i32`.
- Empty braces `{}` are illegal (210_062).
- A **single continuation branch carrying a payload** is illegal → bare return
  `-> T` (210_131) — **unless the tor also has effect branches (`!`)**, which
  make a single continuation branch legal (a `!` arm is a 0..N yield point, so
  the one-variant collapse doesn't apply). All of this is the single-return
  family: [[frag-single-return-form-is-universal]].

## Position 2 — BINDING: `{ … }` is a DESTRUCTURE

`~E() | ok { a, b } |> …` — at a flow continuation (a binding site), the `{ … }`
after a branch **destructures** the matched payload. It is a **binding form**,
not a declaration:

- It binds field **names** from the payload. `| ok x` binds the whole payload;
  `| ok { a, b }` unpacks fields `a` and `b`.
- Grammar per field (parser doc, parseDestructureFields): `name` (bind),
  `name: Type` (bind with a representation annotation — LEGAL here), `name: {…}`
  (nested destructure), `_` (discard the slot). So a `:` in binding position is
  not a decl type — it's a representation annotation or a nested shape.
- **Every destructured name must be a field of the payload.** This is the wall
  that was missing: `| ok { nonexistent }` (KORU036, 210_147) and any field the
  branch payload lacks. Before the wall, an unknown field sailed through parse
  and shape-check and surfaced as a raw host Zig `no field named` leak from
  generated code — the koru-level diagnostic did not exist. Enforced in
  shape_checker (Stage C) against `branch.payload.fields`; wildcard and identity
  (`__type_ref`) payloads have no named fields to destructure, so they're
  skipped. Positive guard: 210_148 (`{ a }`, `{ a: i32 }` of real fields).

## Why position, not shape

`{ blah }` *looks* like it must always be a destructure, but we support richer
destructuring than flat names (nested `pos: { x }`), and the parser routes on
POSITION: a decl payload is parsed as a Shape; a binding `{ … }` is parsed as a
destructure. So the same text is a shape here and a destructure there.
Destructuring **never** happens in a declaration. When a `{ … }` mis-behaves,
the first question is which position it's in — that's what fixes the reading.

Open (Lars, 2026-07-15): is the `name: Type` representation annotation in a
binding destructure an intended, kept feature, or something to revisit while
formalizing the spec? Treated as legal grammar until ruled otherwise.
