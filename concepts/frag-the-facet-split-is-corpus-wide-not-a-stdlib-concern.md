---
type: belief
id: frag-the-facet-split-is-corpus-wide-not-a-stdlib-concern
provenance: js-parity wave W3 — the whole of 200_COMPILER_FEATURES triaged fixture by fixture, port versus exclude, against the open question this fragment left standing
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

## A second triage, from the cluster where the fear should have bitten hardest


This fragment left an open question: whether the 361 want per-test `.kjs`
facets at all, or whether a large share are Zig-semantics tests whose
Koru-side meaning is "the Zig backend rejects this". The whole of
`200_COMPILER_FEATURES` — the cluster where that fear should bite hardest,
because its subject genuinely is the compiler — has now been triaged fixture
by fixture. **The fear was wrong, and wrong by an order of magnitude.**

Thirty-seven fixtures. Three are Zig-by-construction. The rest are ordinary
programs.

The discriminator is not the cluster, the directory, or what the test's
comment claims to pin. It is one property of the `|zig` body itself:

> **A proc body that imports the compiler's own Zig modules (`@import("ast")`,
> `@import("ast_functional")`) or receives a compiler-owned pointer
> (`*const Program`, `*std/compiler:CompilerContext`,
> `*std/compiler:ErrorReporter`) is compiler-host code. Everything else is
> program code, and program code ports.**

That line is mechanical, so it can be applied without reading the prose at
the top of a fixture — which matters, because the prose is systematically
misleading here. A test named `template_interpolation` sitting in
`210_PARSER` reads like a parser probe and is in fact a `[comptime|transform]`
event that builds `ast.EventDecl` and `ast.ProcDecl` values by hand. A test
named `void_chaining_codegen` reads like a backend probe and is three
four-line procs that print `Work`. **What a compiler-features fixture is
*about* says nothing about what host language it needs.** It is about the
compiler; it is written as a program; the program runs anywhere.

The three exclusions are not a deferral or a shortfall. They are the
`[comptime|transform]` surface, and that surface is Zig by ruling, not by
accident: `OUTSTANDING_DESIGN_DECISIONS.md` records Lars, 2026-06-17 —
*"allowing the Zig backend to catch real mistakes is completely fine. It's
not the way it's going to be forever, but for now I think it's great"* — the
"rejection deferred to Zig" model the compiler-facing surface is built on. A
transform manipulates the Zig compiler's own AST types in the Zig compiler's
own address space. There is no JavaScript equivalent because there is no
JavaScript compiler, and inventing one to make a fixture green would be
asserting a design nobody has made.

What generalises to the remaining slices: **estimate the exclusion set from
the `|zig` bodies, never from the cluster name.** The prior that
`200_COMPILER_FEATURES` would port poorly came from its name, and the name
was the least informative thing about it.
