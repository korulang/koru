---
type: belief
id: frag-json-decode-has-two-regimes-schema-and-dom
provenance: measured during json-dom commission then extended during yaml-dom (snow-yarrow fires) — 642_005/006 and 646_001/002 green while landing; yaml.kz's Document IS std.json.Parsed(Value) built by hand from libyaml events, 2026-11-05
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
strings into the arena, so the input text is freeable immediately.

**Extended by std/yaml (same day):** the DOM is format-agnostic, not
JSON-shaped. `std/yaml:parse` assembles `std.json.Value` nodes from the
libyaml event stream and hands out the identical `*Document<open!>` —
every `dom.*` tor navigates a YAML tree unmodified and `dom.render`
gives `-o=json` for free. Any format that can land data in the Value
union inherits the entire navigation surface; the parser is the only
format-specific work. Core-schema bound kept: keys arrive as text,
anchors/aliases refuse `malformed` rather than expanding a graph into
a tree, `malformed` is `string<std/io:allocated!>` (allocated payload —
static strings would be freed into unallocated memory).

Measured while landing:

- Phantom obligations are MODULE-namespaced: `string<emitted!>` inside
  `std/yaml` mints `std.yaml:emitted`, which `emit.free` refuses —
  `string<std/json:emitted!>` qualifies the obligation back to the
  owner.
- Container `Value`s must attach to parents only when COMPLETE —
  `ObjectMap.put`/`Array.append` mutate the header in place, so a copy
  made at START-event time goes stale (root landed empty).
- Proc bodies carrying effect branches splice into the caller —
  module fns/types/consts reached from them take `$mod.` prefixes
  (KORU112).
- `ArrayList` is unmanaged in 0.15.2 — `std.array_list.Managed` is the
  init(allocator) shape; `pop()` returns `?T`.
- An arena created mid-stream needs a defer that destroys it when the
  malformed path never handed ownership to `! doc` — otherwise the
  error path leaks what the happy path's obligation would have owned.
- Optional terminal arms (`| ?wrong-kind`) may not carry `_` bodies —
  KORU054; an unarmed optional arm already discards. Required arms take
  the discard.
- Arm names are choke-level: same-named arms from different tors at one
  level must agree on payload type (KORU031).
- `Stringify.value` on `std.json.Value` mixes its generic union walk
  with `Value.jsonStringify`'s writer-stream separators and emits a
  doubled comma between elements (0.15.2) — `dom.render` writes a small
  recursive serializer instead.

Open: no escape from `*JsonNode` borrow to owned copy — a node cannot
outlive its document today; a `dom.copy`-shaped leaf is unwritten.
`malformed` carries the diagnostic text; dom.parse's variant carries
the Scanner's error name only, no offset.
