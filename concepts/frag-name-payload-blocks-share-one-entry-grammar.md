---
type: belief
id: frag-name-payload-blocks-share-one-entry-grammar
provenance: tightening replay 15 review 2026-09-25 — Lars proposed coupling the const-block and proto-block languages; measured against the tree before answering
ts: 2026-09-25
tags: [koru, field-list, proto, const, source-block, grammar]
---

# Every `{ name: payload }` block speaks one entry grammar; the consumer owns only the payload's meaning (belief)

`const { … }`, the proto doors (`std/types:proto`, `std/proto`, `std/n`), store
seeds, capture blocks, kernel field lists — all are the same surface shape:
entries of `name: payload`. The grammar that *couples* them is the entry layer:
an entry has a name and a payload, entries separate per the door's convention,
and the same four faults are refused with the same vocabulary — nameless,
typeless, fused for want of a separator, and a name bound twice.

Payload interpretation is NOT shared. `const` lowers expressions, proto checks
its type vocabulary (scalars this rung; compounds/`ref`/`<:` in `std/proto`),
store interprets write values. Coupling the grammar never means one payload
domain.

## The ruling (Lars, 2026-09-25)

Coupling the block languages is wanted, and two constraints bound it:

- **Unambiguous, and no comma litter.** In proto doors a comma is not a field
  separator — entries separate on lines, one `name: type` per line. A comma in
  a proto field list is a wart or a fused second field; it refuses, it does not
  parse. `const`/`table` keep comma-or-newline because their expression
  payloads already carry meaningful commas (`@as(i32, 5)`).
- **Hand-drawn is acceptable while the de-slop census runs.** Three hand-rolled
  line loops today (`types.kz` proto, `proto.kz`, `proto.resolve.kz`'s parent
  re-scan) plus the `parse_fields` template filter — a fourth honest copy beats
  a premature shared scanner; the census decides what deserves sharing.

## The measured hole is closed (2026-10)

The proto doors' line loops used to refuse a fused same-line entry with the
wrong reason (`unsupported type 'i32 serial: string'` — the fused tail
misread as part of the type) and never checked a name bound twice:
`proto(Dup) { rpm: i32 / rpm: i32 }` + `std/list:new(Dup)` reached Zig as
`duplicate struct member name 'rpm'` (measured 2026-09-25 at ab5ec044d).

Each of the three loops now keeps a seen-set and runs
`struct_literal.fusedFieldLine` on the payload before interpreting it —
exactly the fix the hole note prescribed, no shared scanner. Duplicate names
refuse `KORU173` ("field 'rpm' is bound twice — a proto entry takes each
field name once") at `std/types:proto`, `std/proto`, and the `<:` parent
re-parse; fused lines name the second field's fragment ("'serial: string'
began a new field on the same line"). Inherited-field merge semantics are
unchanged — the seen-set scopes to one block's text, so a child re-binding a
parent field still deduplicates rather than refusing. Pinned by
665_015–019.

## The ruling is now enforced (2026-10): the wart refuses, not parses

The 2026-09-25 ruling — "a comma in a proto field list is a wart... it
refuses, it does not parse" — was ahead of its implementation: every
one-per-line block grammar tolerated a *trailing* comma by trimming it
silently. The drift was in four places: `protoFieldBlock` in both its copies
(proto.fields.kz, types.fields.kz), `std/types:enum`'s tag walk, and
`std/foreign:struct`'s field walk. All four now refuse a `,` anywhere in a
live-source line (`KORU173`, "fields separate on lines; a comma is a wart,
not a separator"), while the erased `// proto Name: f: t, g: u` marker keeps
its `comma_separates` convention — commas are *legal inside our own emitted
markers* and illegal in author source. Pinned by 665_023 (std/proto door),
665_024 (std/types:proto door — the second copy is pinned separately
precisely because it can drift), 665_025 (enum), 667_007 (foreign).

One deliberate exclusion: store view seeds (`{ <: A, <: B }`) keep commas —
their member list is a comma-separated set on ONE line, not a line-per-entry
block, so the comma is a real separator there and the rule does not apply.
The ruling's scope is line-delimited entry grammars; a comma that does
delimiting work is not a wart.

What would correct this: a live-source block where a comma legitimately
separates two entries on one line — a grammar that grows multi-entry lines
reopens the separator question.

## The host-struct lift is the same surface (2026-10-27)

A `pub const Name = struct { ... }` declaration the host-struct lift
parses (`parseHostStructDecl`) is one more `{ name: type }` entry list —
and it carried none of the four faults: `x: i32` beside `x: i64` reached
Zig as `duplicate struct member name 'x'` (rung 3). The lift's field loop
now keeps a seen-set, PARSE010, caret on the second field's name.

**"Bound twice" is a property of the emitted name, not the source
spelling.** Kebab `-` mangles to `_` at identifier formation on every
target, so `a-b` and `a_b` are distinct spellings that write one member —
the same rung-3 hole behind a different spelling. The shared comparator
(`struct_literal.emittedFieldNameEql`) compares emitted names; the
struct-literal seen-set, the AST-level field/destructure/jump-arg checks,
and the host-struct loop all gate on it. Own-loop copies that still
compare raw spellings (protoFieldBlock's two instances, tree.registry's
parseNodeFields) are the same hole, unprobed there — worth the same
one-line adoption when measured.

Pinned by 220_058 (host struct), 210_332 (branch payload, mangle
collision).
