---
type: belief
id: frag-every-synthesized-slot-is-a-contract
provenance: proto/list-vertical-slice branch, 2026-08-23→24 — two memory-corruption faces of the same synthesis discipline, first misdiagnosed via lldb as one bug
ts: 2026-08-24
---

# In AST synthesis, every slot you allocate is a contract you must fill (belief)

Hand-built AST synthesis (`synthesizeContainer` in `koru_std/list.kz` and its
siblings) constructs items over raw allocator calls and hands them to later
passes through the program splice. Two distinct memory faces of the same
discipline have now bitten, hours apart, and the first was misread as the
second:

**Face 1 — stack literals.** `&[_]astz.Field{f}` with a runtime element
materializes block-scoped; the slice dangles when the block ends, and the next
whole-program clone reads freed bytes. Fixed by heap-building field lists
(`fields1`), documented at the site.

**Face 2 — the unassigned slot.** `alloc(Field, 2)` with only `in[1]` written:
`in[0]` stays Zig-undefined (`0xaa` fill), flows into the spliced event_decl,
and a later pass (`Phase 2.6` rescan reading `field.@"type"`) dereferences
poison. Found only because a flagship proof segfaulted; no pin covered the
proto-derived path, so the scalar pins stayed green while the compiler was
broken. Fixed by assigning `in[0]`; pinned by 660_028.

## The ruling-shaped line

An allocation whose slots are filled *by the same expression* (a literal, a
constructor call) carries its completeness visibly. An allocation whose slots
are filled *by index across statements* makes "did I fill them all?" an
uncheckable side condition — and the checker that eventually reads the missing
slot is modules away from the loop that skipped it. Prefer constructors or
literals-on-heap that make omission unrepresentable; where indexed filling is
unavoidable, the count of assignments must be re-read against the alloc length
like a contract clause.

## Why the pins missed it

Coverage of a synthesis path needs a test that walks THAT path: the six 660
scalar pins exercised push/len/pop over `new-i64()` and never entered
proto-derived synthesis, so a broken push event decl shipped green. A green
board over a partially-synthesized surface proves the walked paths only.

## Open question

Whether Debug-only `0xaa` fill is enough of a canary for ReleaseFast builds —
the produced program may read the garbage silently there. Unmeasured; the
pin runs in the suite's default optimization, not ReleaseFast.
