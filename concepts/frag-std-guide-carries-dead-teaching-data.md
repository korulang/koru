---
type: belief
id: frag-std-guide-carries-dead-teaching-data
provenance: 2026-11-09 — std/guide landed: attach transform + module-as-tor lookup proven end-to-end in 480_001
ts: 2026-11-09
---

# A program can carry dead teaching data on its transitions — harvested by transform, served by key

`std/guide` establishes that a Koru program may attach prose teaching
surfaces to its own transitions as inert AST data: `guide:add(tor -> branch)
{ lesson }` is a `[comptime|transform]` marker whose proc harvests
`(canonical-key, template)` pairs at compile time; `std/guide(tor -> branch)`
is a `pub tor default` lookup returning `| guide template | not-found` with
exact-match-beats-wildcard specificity.

The belief this encodes: **the state machine is enumerable, so pedagogy can
be attached to edges rather than centralized in a prompt.** Every deviating
edge is a declared, addressable site; teaching is dead data until a lookup
asks for it; silence (`not-found`) is the default so lessons cost nothing
until relevant. The same `src -> dest` transition idiom as `std/taps` keeps
the attach syntax consistent with the language's existing edge vocabulary.

Open questions the belief does not yet answer: module-resident `add`
invocations inside impl flows lose their `{...}` source block to the outer
tor's body (KORU080 — pinned TODO in 115_063, needs grammar
disambiguation); delivery is file-based (`guide_table.txt` beside the
executable) and the production path is `SiteResult.appended` AST injection;
transform-side module resolution is verbatim-expr only; nothing yet renders
templates against live interpreter state — that is the pedagogy layer's
next layer, not this one's.
