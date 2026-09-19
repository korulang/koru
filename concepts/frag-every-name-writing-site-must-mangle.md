---
type: belief
id: frag-every-name-writing-site-must-mangle
provenance: a commissioned cell in intranquil-domain (WO-002, 2026-09) omitted `pitch-offset` at a .k call site and the injected default emitted `.pitch-offset = null` — a Zig syntax error. The same defect existed in four places at once; pinned as 400_194.
ts: 2026-09-22
---

# A declared name is not a Zig identifier — every site that writes one into emitted code must mangle, and the rule had four copies, all wrong the same way

Kebab is not an edge case in Koru — it is the house spelling (`pitch-offset`,
`set-color`, `note-region`). `.k`-parsed names get normalized at parse time,
but **`.kz` host declarations do not**: a tor's input-shape field name reaches
the emitter still carrying `-`, and any site that writes `field.name` into
emitted Zig without mangling produces a syntax error in code the author never
wrote.

The shape that made this expensive: the OPTIONAL PARAMETER INJECTION rule
(omitted `?T` fills `null`) existed in **four separate emission paths** —
the top-level emitArgs, two impl-flow twins in emitter_helpers, and the
subflow path in visitor_emitter — each an independently maintained copy, and
every one wrote `field.name` verbatim while the explicit-arg path right
beside it correctly used `writeBranchName`. Explicit `pitch-offset: 48`
compiled; omitting it broke. The asymmetry is what made it a bug rather than
a convention: the corpus exercised kebab optionals *provided* everywhere,
but never *omitted* — `400_180` pinned the injection with a non-hyphenated
name, so the cross product of two independently-covered features was the
hole.

The ruling: **name-writing is a mangle-or-die site, not a borrow-the-string
site.** `writeBranchName` (kebab→snake, keyword-escapes) is the single
spelling for any declared name reaching emitted Zig — field names, branch
names, arg names — and a new emission path that re-implements an existing
rule (like the four injection copies) inherits every defect the original
had plus whatever it adds itself. The adjacent latent class is flagged, not
fixed: `bc.fields` loops (~16 sites) emit `.{ .field-name = }` branch-payload
literals with the same verbatim write — a kebab branch-payload field name
would hit the identical wall, unexercised today.

2026-09-22, second surface of the same belief, pinned 230_019: the rule is
not only *sites that write a name* but *text that contains one*. A `: i1`
bind declares `@"i1"` and `pos-tempo` declares `pos_tempo`, yet every
reference downstream lives inside author text spliced verbatim — template
`{{ expr }}` holes, when-guards, arg values, `_ = &x` discards. `i1`
resolves as the primitive type, `pos-tempo` parses as subtraction; both
yield "undeclared identifier" in generated code the author cannot open.
Decl and use must carry ONE spelling, and the use side is unfixable site by
site — a reference can hide inside arbitrary rendered text — so the correct
shape is a rewrite pass (`escapeBoundNames` over `replaceIdentifier`, the
established code-masked word-boundary rewrite) run at the text funnels:
`lowerExprZig`, the rendered inline body, raw arg-value writes, and every
`_ = &` discard. The funnel is the invariant's home; a name caught at all
thirty-odd call sites individually would drift again the same way the four
injection copies did.

Related:
[[frag-the-safe-koru-identifier-surface-is-smaller-than-the-language-says]] —
same wall seen from the author's side (keywords/primitives); this is the
emitter's side, and kebab is canonical, not exotic.
[[frag-a-name-mangling-dispatcher-assumes-a-parity-nobody-maintains]] — the
four-way copy is the same maintenance failure: N writers of "the same" rule,
zero owners of the parity.
