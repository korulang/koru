---
type: belief
id: frag-comments-are-first-class-ast-items
provenance: koru-surface.js re-implements comment grammar in JS (stripComment, commentBlockAbove, banner filtering, commented-out-code heuristics) because --ast-json dropped comments and line numbers — doc-gen was rescanning source text to recover what the AST should carry. Lars ruled the shape 2026-11-08 after the adjacent-session analysis.
ts: 2026-11-08
---

# Whole-line comments are .comment AST items — additive alongside host lines

A `.comment` item is a maximal run of whole-line comment-or-blank content,
one item per block, verbatim bytes including delimiters and interior
blanks, location at the first comment line. Per-facet syntax: `//`
everywhere; `/* … */` with cross-line state only for `.kjs`/`.kc`/`.kcs`/
`.kgpu` — Zig and `.k` have no block comments.

In host facets the same bytes ALSO remain per-line `host_line` items: the
byte channel is authoritative for emission and is untouched by
construction; `.comment` is the semantic channel for tooling — docs,
glance, IDE, block editors. `.k` emits `.comment` alone (no host channel).
This is the first time information is *extracted* from opaque host lines
into typed AST citizens — `host_type_decl` promotion is the sibling
precedent, but comments duplicate rather than replace because they do
not own emission (dead_strip strips them as cargo).

Deliberately out of scope, ruled same session: trailing `code // note`
(attached to code, a different concept), comments inside decl interiors
and flow chains (KORU010 stands), proc bodies (opaque host text), `.kmd`
(document content), `.k` `/* */` (parses-as-call quirk, separate
language question). `//@koru:` and transform marker lines keep their
`host_line` channel — a parse-time classifier never sees them anyway.
Doc-gen-level filtering (banners, commented-out code) stays consumer-side:
the parser owns extents, not taste.

Open: whether decl-interior trivia and trailing comments ever earn
node-level trivia fields; whether `.k` grows block comments as a
language decision; the koru-surface.js migration onto `.comment`
content from --ast-json.
