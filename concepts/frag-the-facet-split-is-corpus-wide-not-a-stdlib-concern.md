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

The triage that question asks for is now made for 51 of the 361 — the
`330_PHANTOM_TYPES` slice — and it came back **51 for 51: every one wanted
the facet, and not one was a legitimate Zig-only exclusion.** That slice was
not a soft sample. It was picked precisely because it is the most
Zig-idiomatic corner of the corpus: nearly every fixture opens with
`std.heap.page_allocator.create(File)` followed by `f.* = File{...}`, which
reads like host-semantics testing and was flagged in advance as the likely
home of the Zig-only exclusions. It contains none. What those tests pin is
the **obligation lifecycle** — that a debt is issued once and discharged
exactly once, and in what order the trace prints. The allocator is the
cheapest way to get a distinguishable resource in Zig, not the thing under
test, and a plain object literal is a faithful model of it. `destroy` ports
to nothing at all, because nothing observable depended on it.

So the sharpened belief: **"this test is written in Zig" and "this test is
about Zig" are independent, and host idiom is near-worthless evidence for
the second.** The exclusion set is real but it is characterised by what a
fixture *observes* — a raw pointer value, integer wraparound, a thread
identity, a child-process exit code — never by what it *allocates*. Triaging
on idiom would have written off this entire slice unexamined.

The 361 are correspondingly less of a mountain than the count suggests, but
the reason the number moves is not that the ports are easy. It is that the
residue after a complete port is **not fixture work at all**. Four of the 51
stayed red, and every one names a JS-emitter construct gap — a metatype
binding, a call-site destructure bind, a label-fold that only lowers when
`#loop` is the flow head. No `.kjs` can close any of them. The facet is
necessary and not sufficient, and once the necessary part is done the
leftover is a clean readout of emitter gaps. That makes this population a
better instrument than it looks: porting a slice is also a survey of what
the target cannot yet say.
