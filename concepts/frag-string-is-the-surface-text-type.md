---
type: belief
id: frag-string-is-the-surface-text-type
provenance: introduced by the string-canonical walk — reverse the text-type wall (2026-07-17)
ts: 2026-07-17
---

# `string` is the surface text type; `[]const u8` is only its lowering

Ruled 2026-07-17 (Lars). Text in a Koru **tor declaration** is spelled
`string`. The Zig slice `[]const u8` is not a surface type — it is the internal
lowering `string` compiles to on the native backend, nothing a program author
writes. The old wall pointed the wrong way: `[]const u8` was the canonical
payload spelling and `string` was rejected as a foreign-language habit
(PARSE003 "Unknown type 'string'... use '[]const u8'"). That is repudiated. The
wall reverses: `string` accepted, `[]const u8` rejected, in BOTH `.k` and `.kz`
(a `.kz` file is still Koru surface at its tor declarations; host-adjacency
does not license the ziggy spelling there), and in **every surface type
position** — payload fields (braced + braceless identity + `!` effect payloads),
**and return/resume positions** (`-> string`). There is no half-canonical
state where payloads are `string` but returns stay `[]const u8`.

**`string` is PRESERVED through the whole pipeline, lowered only at emission.**
This is the load-bearing decision (Lars, 2026-07-17): *"do this correctly and
keep the const u8 array out of the top surface… not the right time to introduce
hacks where we're masquerading a string but keeping it a `[]const u8` under a
shallow surface."* So the parser does NOT rewrite `string`→`[]const u8` at parse
time. The AST carries `string` verbatim — the printer, serializer, and
round-trip all read back `string`, which is what makes it a *real* type rather
than sugar that vanishes. `[]const u8` is emitted only at the Zig backend
boundary, through a single `lowerZigType` helper wired into every type-emission
chokepoint (struct fields, destructure binding consts, bare-return `Output=`,
effect resume/arm types, field defaults). A JS backend lowers the same surface
`string` to `String`; that per-target freedom is *only possible because `string`
survives to emission* — eager-lowering at parse would have destroyed it.

Repudiated along the way (the eager-lowering false start): rewriting
`string`→`[]const u8` at parse "because the Zig lowering is trivial" seemed
fine, but it made the AST show `[]const u8`, broke round-trip (`string` in,
`[]const u8` out), and made `[]const u8` the real type with `string` a fiction —
the exact masquerade the ruling forbids. The round-trip unit tests are the wall
that caught it.

The irreducible whys — what the tests (020_060 positive, 510_105 negative)
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
- **Same runtime behavior, one word.** Lowered, `string` IS `[]const u8` — same
  representation, same performance. 020_060 is 020_016 with one word changed and
  identical output. The difference is entirely at the surface/AST level.
- **Obligations forced the return-position canonicalization.** An `acquire ->
  string<held!>` produces a `<held!>` obligation whose discharge tor
  `release { name: string<!held> }` must match by *type*. When payloads were
  migrated to `string` but returns left as `[]const u8`, the produced type
  (`[]const u8`) no longer matched the consumed type (`string`) and auto-discharge
  failed (KORU030). This is *why* the return-type deferral was incoherent and had
  to be closed: a half-canonical surface breaks obligation type-matching
  (335_050/051, 834_mutex_unlock).

Deliberately held shut this pass: **`string` does not own its bytes.** It stays
a borrow/value, immutable by default — semantically identical to today's
`[]const u8`. An *owning* string (heap-allocated, carrying a discharge
obligation) would enter the resource/obligation system and is a separate, later,
deliberate ruling — it must not ride in for free under a rename.

`[]const u8` in a plain `const` binding or inside a raw `~…|zig` body stays legal
— that is still Zig, not surface. See [[frag-type-system-design]] (payload types
as registry-checked, not host strings) for where this sits in the larger type
story. Pins: 020_060 (payload positive), 510_105 (payload reject), 510_104
(return reject).


---

**Evolved 2026-08-22 (containment cascade).** The rejection half of the ruling
was a spell-checker: three `std.mem.eql(t, "[]const u8")` sites let every
spelling that merely CONTAINS the slice walk past — `[][]const u8`,
`?[]const u8`, `*[]const u8`, `Handle<[]const u8>` compiled clean to a binary
(510_108 held this gap open, deferred 2026-07-25 to "the wider sweep"). The
sweep ran: the wall is now quote-aware **containment** — if the raw slice
appears anywhere in a surface type text, in any position (return, inline
payload, braced payload field), PARSE003 fires. Corollary the equality wall
could never express: **`string` composes.** A slice of text is spelled
`[]string`, an optional text `?string`, and both are first-class surface types,
not escape hatches back into host spelling.

Lowering followed the composition: `lowerZigType`, `writeFieldType`, and
`writeBareReturnType` now recurse through `?`/`[]`/`[]const ` prefixes and lower
the base at every depth — `[]string` emits `[]const []const u8`. The emitted
slice levels are **const**: text is immutable, and the host command ABI hands
`argv` over as `[]const []const u8`, so a mutable element type there is a
compile error in the dispatcher. Pins: 510_104-107 stay green, 510_108 flipped
green, and the corpus migrated (~20 stdlib surface positions, ~12 fixtures);
210_008's expected.json records that AST JSON embeds resolved stdlib type text,
so a surface spelling change is visible in pinned ASTs.
