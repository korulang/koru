---
type: belief
id: frag-json-decode-has-two-regimes-schema-and-dom
provenance: measured during json-dom commission (snow-yarrow fire) — 642_005/006 green while landing; recursion probe compiled and ran before the design settled, 2026-11-05
ts: 2026-11-05
---

# JSON decode has two regimes: schema-at-compile-time and DOM-at-runtime

Belief: `std/json` decodes through two sibling surfaces with disjoint
contracts. The comptime `std/json:parse` transform reads the `ok`
branch's destructure as the schema and emits a bespoke typed parser —
no tree exists, field values are arena-scoped to the branch. The `dom`
part (landed 2026-11-05, `json.dom.kz`) materializes the document for
access paths not known at compile time: `dom.parse` yields an owned
`*Document<open!>` over a `parseFromSlice` arena, `dom.val` dispatches
all eight Value variants for typed descent, `dom.at`/`dom.idx`/`dom.each`
navigate, `dom.render` serializes to `string<emitted!>` (discharged by
`emit.free`).

Every `*JsonNode` borrows into the Document's arena — valid while the
document lives, untracked like `split`'s pieces. `dom.parse` copies all
strings into the arena, so the input text may be freed immediately.

Measured while landing (642_005/006):

- Optional terminal arms (`| ?wrong-kind`) may not carry `_` bodies —
  KORU054; an unarmed optional arm already discards. Required arms take
  the discard.
- Arm names are choke-level: same-named arms from different tors at one
  level must agree on payload type (KORU031) — `at`/`idx`/`len` got
  `found`/`elem`/`count` rather than `ok`.
- Hyphenated arms emit underscore union members: `.@"wrong-kind"` is a
  miss, `.wrong_kind` is the member.
- `Stringify.value` on `std.json.Value` mixes its generic union walk
  with `Value.jsonStringify`'s writer-stream separators and emits a
  doubled comma between elements (0.15.2) — `dom.render` writes a small
  recursive serializer instead.

Open: no escape from `*JsonNode` borrow to owned copy — a node cannot
outlive its document today (the `parse` transform's scoped-borrow rule,
one level down); a `dom.copy`-shaped leaf is unwritten. `malformed`
carries the Scanner's error name only, no offset.
