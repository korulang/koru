---
type: belief
id: frag-a-register-of-guards-must-be-derived-not-written
provenance: the wall census of 2026-07-31 — a hand-counted inventory found 40 guards, several unremembered; the register was then made a derived artifact (scripts/WALLS.md + scripts/wall_check.sh) because a written one rots into the exact defect it documents
ts: 2026-07-31
---

# A register of guards must be derived, not written, because a written one rots into the defect it documents (belief)

The wall census set out to answer: which of our test-quality rules are
compiled into the harness, and which are still prose? The counting worked —
40 guards, several of them forgotten within weeks of being built
([[frag-compliance-is-counted-with-the-enforcers-predicate]] records what a
forgotten wall costs: the same corpus measured 75% rotten twice by someone
using the wrong predicate, when the true number was 2%).

The trap is in what happens to the census after it is delivered. A markdown
inventory of walls is itself prose about enforcement — exactly the artifact
class whose decay created the need for a census. In three weeks it is stale;
worse, it is stale *and trusted*, because it looks authoritative. A stale
register of guards reproduces the original defect with interest: now there is
a document confidently naming walls that no longer exist and omitting walls
that do.

## The shape that avoids it

The repo already had the answer twice, which is what qualifies this as
compiled doctrine rather than invention:

- `scripts/registry_check.zig` — the inventory of diagnostic codes is not a
  document, it is a diff between DECLARED, EMITTED and PINNED, taken fresh
  from source every run.
- `prose_check.sh` check D — the inventory of comptime transforms is a
  manifest (`COVERAGE.md`) that an extractor diffs against the declarations,
  so a new transform fails the suite until someone accounts for it in
  writing.

The wall register copies that second shape. The extractable half of the guard
surface — every literal the harness can write into a `FAILURE` file, plus the
named watcher checks — is pulled from the sources each run and diffed against
`scripts/WALLS.md`. A guard added without a row is UNREGISTERED; a row whose
guard has left the harness is STALE. Guards with no extractable identity
(runner refusals, locks, walls spelled as tests) get anchor rows: a file plus
a literal that must still be present, so at least their *removal* is loud.

## The honest limit

Derivation only covers what has a mechanical identity. Three tiers, in
descending confidence:

1. **Extracted** (verdicts, watcher checks) — complete by construction; a new
   one cannot ship unregistered.
2. **Anchored** (locks, refusals, test-walls) — removal is caught; *addition*
   of a new unanchored guard of this kind is not. The register is only as
   complete here as the last person who added a row.
3. **Accidental walls** ([[frag-a-test-can-be-load-bearing-by-accident]]) —
   no identity to extract, no anchor to check. Not in the register, stated in
   its header, and that statement is load-bearing: a register that implied
   completeness over this species would be lying in the one place that must
   not.

Related: [[frag-a-wall-guards-one-direction-of-a-symmetry]] — the register's
mirror column exists because the highest-yield census question is not "what
rule has no wall" but "what direction does each existing wall not cover."
