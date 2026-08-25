---
type: belief
id: frag-a-bare-return-resolves-its-home-from-the-lifted-return-phantom
provenance: emitter fix during the AoC-2015 close-out session, 2026-08-26 — discovered by respelling 660_027 past PARSE003 and watching the Output emit undeclared
ts: 2026-08-26
---

# A bare-return type's home module comes from the lifted return_phantom (belief)

The parser splits a tor declaration's `-> T<phantom>` into two AST fields:
`return_type` keeps the base (`*List_i64`), `return_phantom` keeps the
bracketed text (`std/list:list!`). Every consumer that wants to know what the
declaration MEANS must consult BOTH. On 2026-08-26 exactly one did not:
`writeBareReturnType` emitted the handler `Output` (and the call-site result
annotation) from `return_type` alone, so a foreign-handle return emitted the
bare base name — `pub const Output = *List_i64;` — an identifier that exists
in no scope outside the home module. Payload INPUT fields never had this bug,
because their phantoms ride `field.phantom` next to `field.type` and
`writeFieldType` already resolved homes from them.

The fix ratifies symmetry: a module-qualified phantom on a bare-return type
names the base type's home module, resolved through the same registry evidence
(`moduleDeclaresType`) that payload lowering uses, at BOTH emission sites
(handler Output and call-site annotation). This is the return-position twin of
[[frag-bare-phantom-resolves-to-base-type-module]] — that belief governs how
the CHECKER canonicalizes states; this one governs how the EMITTER lowers the
type reference so the emitted Zig can even name the type.

## Why this mattered more than an emitter nit

The stale Output was the last thing standing between the corpus and its own
ruled spelling. 660_027 (Lars-ruled 2026-07-02: `<std/list:!list>` consumes,
`<std/list:list!>` issues, linear transfer checked in pure impls) was written,
pinned, and then LEFT RED on PARSE003 when the bare-return migration landed —
so for eight weeks the ledgers of AoC days 7, 10, and 22 honestly reported
"no owned collection handle can pass through any user event" about a wall that
was actually a door with a deadbolt painted on. Respelling the declaration to
`-> *List_i64<std/list:list!>` and fixing this emitter gap turned 660_027
GREEN the same hour. The obligation system needed NOTHING.

## Consequences

- **Qualified-phantom passthrough through user tors is LIVE end-to-end** —
  declare the param `<home:!state>` to consume, the return `-> T<home:state!>`
  to reissue; pure impls are checked for linear transfer. First AoC consumers
  are pending (days 7/10/22 respells); day 5 part 2 already borrows
  string-maps through user tors under the same spelling.
- **Any new emission site that lowers a return type MUST route through the
  reattachment** (or read `return_phantom` directly) — a site that reads
  `return_type` alone will silently re-create this class of bug for every
  foreign handle.
- **A red test can be stale in BOTH directions.** FRONTIERS entries and test
  ledgers described this surface as missing while its acceptance test sat red
  on syntax rot two feet from the truth. When a ruled spelling predates its
  pinned test's syntax era, check whether the wall is real before re-proving
  it absent.

Pinned by: `660_027_obligation_param_qualified_phantom` (green 2026-08-26),
first exercised across modules by `810_052_day05_part2`'s map-borrowing walk.
