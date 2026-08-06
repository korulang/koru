---
type: belief
id: frag-the-facet-split-is-corpus-wide-not-a-stdlib-concern
provenance: first js-scan sample — 14 of 20 "emitter-testable" tests died on js_emitter NoJsProcBody, from the fixtures' OWN |zig procs rather than any stdlib gap
ts: 2026-08-06
---

# The `.k`/`.kz`/`.kjs` split is a property of the corpus, not a stdlib migration

Planning the JavaScript target, the facet split was scoped as a **stdlib**
prerequisite: `koru_std/*.kz` must become `.k` contract plus `.kz` bodies
before a `.kjs` sibling can carry JavaScript implementations. The frontier
map was built on that scope, and classified a test as emitter-testable when
every stdlib proc it *called* had a `|js` body.

The first scan contradicts that flatly. Of 20 sampled emitter-testable
tests, 14 failed with `js_emitter.emit failed: NoJsProcBody` — and not one
of those was a stdlib gap. **The fixtures carry their own `|zig` procs.** An
`input.kz` is Koru with Zig bodies exactly as a stdlib module is, and the
emitter aborts on the first local proc with no `|js` sibling, long before
any stdlib call matters. Re-derived across the corpus: **361 of 931
positive tests are blocked on their own host code**, against 347 blocked on
the stdlib. The population nobody had modelled is the larger of the two.

The belief this leaves us with: **`.kz` means "Koru with Zig bodies"
wherever it appears, and every `.kz` in the tree owes the same three-way
split.** The stdlib is not a special case, it is merely the instance we
happened to look at first. A migration plan scoped to `koru_std/` would
have completed and left roughly 39% of the suite still unable to reach the
JS emitter at all — with the plan reporting success, because the stdlib
number it was tracking would have gone green.

The sharper form, and the one that should govern future targets: a test
fixture is not neutral ground. It is written in a host language, and any
claim of the form "this test exercises the compiler, not the platform" is
false for every `.kz` fixture. Cross-target parity work must count fixture
host code in its denominator from the start, or its first honest
measurement will arrive after the budget is spent.

Open question: whether the 361 want per-test `.kjs` facets at all. Some are
surely Zig-semantics tests whose Koru-side meaning is "the Zig backend
rejects this" (the deferred-rejection rulings in
`OUTSTANDING_DESIGN_DECISIONS.md`), and porting them to JavaScript would be
asserting something nobody has designed. That triage — port versus
legitimately exclude — is unmade, and it is the difference between a 361-item
mountain and a much smaller one.
