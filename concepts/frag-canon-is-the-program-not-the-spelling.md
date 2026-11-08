---
type: belief
id: frag-canon-is-the-program-not-the-spelling
provenance: canon-trivia ruling landed 2026-11-08 chasing BLOCK_EDITOR.md §10 round-trip numbers — 1212 of 1288 tree-diffs were had_explicit_label alone
ts: 2026-11-08
---

# Canon compares programs, not spellings (belief)

`serializeCanon`'s trivia strip IS the definition of "same program" for
the round-trip contract. `location` and `indent` were already stripped
as WHERE-the-source-was-written; `had_explicit_label` joins them as
HOW-the-source-was-spelled — the pun-vs-explicit argument-label
preference is author spelling, and the printer normalizes to explicit,
so the flag can never survive a print→reparse and must not count as a
tree diff.

Measured effect (2026-11-08, tree 09b5af7+): stripping it collapsed
1212 of 1288 tree-diffs; combined with the harness facet fix (reparse
file mirrors source extension — `.k` prints are `.k` dialect, not
`.kz`), corpus round-trip went 542→1747 pass / 178 fail / 157 skip.
The remaining fails are purely semantic printer gaps — the canon
surface now measures exactly printer completeness, nothing else.

Open questions: whether other provenance-adjacent fields deserve the
same ruling as they surface (`module_path`, transform `marks`,
`produced_by`-style fields); and whether canon-trivia is the right
equality bar permanently or only the right v1 bar — the
teaching-tool-vs-real-editor fidelity ruling (BLOCK_EDITOR.md §10)
decides if untouched-region byte-preservation ever needs a stricter
surface than canon.
