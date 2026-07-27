---
type: belief
id: frag-a-vertical-annotation-block-is-scanned-twice
provenance: built with Lars 2026-07-27 (the claims-registry session) while carrying annotation prose into the AST
ts: 2026-07-27
---

# A vertical annotation block is scanned twice, and the second scan is blind (belief)

The natural mental model of `~[` … `]construct` is a block the parser reads
once, keeping what it recognizes. That model is wrong, and anything designed
on top of it breaks in a way that looks like a bug in the wrong place.

What actually happens: a vertical block is **flattened into a synthetic
`~[a|b]construct` line** and fed back through the dispatcher, which parses it
again — inline. So every vertical block is scanned twice, and the second scan
is structurally incapable of seeing anything the inline form cannot express.
Prose is exactly that: it needs a line of its own, and the synthetic line has
none.

**The consequence that generalizes beyond prose: anything a vertical block
carries that the inline form cannot spell must travel out-of-band.** It cannot
ride the annotation text, because the text is rebuilt from the entry list
alone. It travels on a parser-held stash, and the stash's rule is the
counter-intuitive part — an *empty* value must never clear it, because the
second scan always produces empty. Blocks that turn out to own no declaration
(a module-level annotation, a gated-out import, a construct that failed to
parse) clear it deliberately instead, or their rationale rides forward onto an
unrelated declaration.

Why the flattening exists at all: it lets one code path parse both densities,
which is why vertical and inline blocks provably produce identical entry lists
(the property `310_008` and `310_104` pin). That is a real win and worth
keeping — the cost is only that the block is not the unit the parser sees.

Open, deliberately unresolved: whether the flattening should eventually be
replaced by a block-aware parse that hands the construct its whole annotation
unit at once. That would delete the stash and make the mental model true, but
it touches the dispatcher's recovery paths, which are load-bearing for lenient
mode. Nobody has costed it.

Pairs with [[frag-annotation-entries-are-expressions]] — that belief governs
what an entry *means* (shape, never meaning; consumers own policy); this one
governs what the parser can physically carry.
