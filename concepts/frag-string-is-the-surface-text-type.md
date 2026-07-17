---
type: belief
id: frag-string-is-the-surface-text-type
provenance: introduced by the string-canonical walk — reverse the text-type wall (2026-07-17)
ts: 2026-07-17
---

# `string` is the surface text type; `[]const u8` is only its lowering

Ruled 2026-07-17 (Lars). Text in a Koru **event declaration** is spelled
`string`. The Zig slice `[]const u8` is not a surface type — it is the internal
lowering `string` compiles to on the native backend, nothing a program author
writes. The old wall pointed the wrong way: `[]const u8` was the canonical
payload spelling and `string` was rejected as a foreign-language habit
(PARSE003 "Unknown type 'string'... use '[]const u8'"). That is repudiated. The
wall reverses: `string` accepted, `[]const u8` rejected **in the event-payload
type position**, in BOTH `.k` and `.kz` (a `.kz` file is still Koru surface at
its event declarations; host-adjacency does not license the ziggy spelling
there).

The irreducible whys — what the tests (020_060 positive, 510_069 negative)
cannot themselves say:

- **The surface language owns its own text type.** `[]const u8` names *one
  backend's memory representation* — a slice is pointer+len, a Zig construct.
  Naming a host layout in the surface is a leak, not an abstraction. `string`
  says the intent (text) and lets the emitter pick the representation.
- **Per-target lowering is the point.** `[]const u8` is already a fiction on the
  JS target — JS has no slices; it renders a `String` regardless. So the ziggy
  spelling was a surface type that only the native backend actually used.
  `string` → `[]const u8` on native, `String` on JS, and whatever is fastest
  elsewhere. This is "emitter prefers performance" applied to text.
- **Same behavior, one word.** The flip is non-disruptive by construction:
  `string` maps internally to the exact type `[]const u8` lowered to before.
  020_060 is 020_016 with one word changed and identical expected output.

Deliberately held shut this pass: **`string` does not own its bytes.** It stays
a borrow/value, immutable by default — semantically identical to today's
`[]const u8`. An *owning* string (heap-allocated, carrying a discharge
obligation) would enter the resource/obligation system and is a separate, later,
deliberate ruling — it must not ride in for free under a rename.

Scope of the rejection is the event-payload surface position only. `[]const u8`
in a plain `const` binding or inside a raw `~…|zig` body stays legal — that is
still Zig, not surface — unless a later ruling widens the canonical-form wall to
all surface type positions. See [[frag-type-system-design]] (payload types as
registry-checked, not host strings) for where this sits in the larger type
story.
