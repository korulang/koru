---
type: belief
id: frag-a-claim-key-must-carry-the-variant
provenance: built with Lars 2026-07-27 (the claims-registry session), after the registry falsified the key it was written to serve
ts: 2026-07-27
---

# A claim's subject is not a name — it is kind + module + name + variant (belief)

A claim attaches to a declaration, and a declaration looked like it already had
a perfectly good identity: the module-qualified name the author wrote. That was
the whole argument for *not* minting node identities for claims — no geohash,
no positional key, no authored id, just the name.

The name is not a key. **One event name can have many implementations, and each
one deserves its own claim** — that is the entire point of variants. A reference
implementation that is correct by inspection sitting beside an optimized one
that is only as good as its property test are two different assertions about two
different bodies of code, and a key that cannot tell them apart silently merges
them. The pins are `310_111` (three claims, one rule name, no collision) and
`310_112` (the collision that must be refused); the variant shape they rest on
is `370_VARIANTS/8201_variants_basic`, and `700_EVENT_GLOBBING/700_005` spells
out why the two implementations deserve different stamps.

The second axis is the declaration KIND. A claim on the `tor` is about the
contract — what callers may assume. A claim on a `proc` is about one
implementation. They can disagree without either being wrong, so they must never
share a key.

**Why this belief is worth keeping rather than the fix alone:** the registry
found this before it had a single caller. The rule under test was our own — "the
name is the key" — and running it is what killed it. That is Lars's runnable-
invariants litmus (`6digit-world/docs/RUNNABLE_INVARIANTS.md`) turned on the
design of the checker itself, and it is the argument for building the crash
check first rather than last.

What this belief does NOT claim: that keys survive editing. Rename a subject and
its key changes; the registry sees one key vanish and another appear, never a
move. For claims that is correct — a renamed subject is a different thing, and
an external judgment of the old one should expire rather than silently transfer.
Continuity across edits is a different problem with a different owner (the
projected-editor bed), and it stays there.

Open: whether a rule name needs module-qualifying too. Two modules can each
define `no-alloc` and mean different things; today the rule name is a bare
string and the collision is invisible.

Pairs with [[frag-annotation-entries-are-expressions]] (the layering that lets
std/rules own this vocabulary without the compiler learning it) and
[[frag-a-vertical-annotation-block-is-scanned-twice]] (how the prose beside a
claim reaches the declaration at all).
