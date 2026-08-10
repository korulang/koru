---
type: belief
id: frag-a-text-rewriting-emitter-fails-where-no-compiler-can-see
provenance: session 2026-08-10 (Lars + Claude) — serving korulang.org from Orisha
ts: 2026-08-10
tags: [koru, codegen, emitter, string-literals, silent-wrong-output, testing]
---

A defect in an emitter that **rewrites text** can be invisible to every compiler
on both sides of it, and therefore invisible to the whole test apparatus that
watches compilers. The emitted artifact is well-formed. The host accepts it. The
program links, runs, and returns. The defect exists only in the *bytes it
produces at runtime*.

The prior working belief — never written down, which is exactly why it held — was
that a codegen bug surfaces as a build failure somewhere: either koru refuses,
or the emitted Zig does not compile, or a test's expected output mismatches. Each
of those has a gate watching it. The unexamined premise was that the set of
possible codegen defects is covered by the union of those gates.

It is not. When the lowering from a Koru record to Zig walked its input one
character at a time with no notion of a string literal, a `{` inside a quoted
string was read as the `{` that opens a struct, and collected the leading `.`
that Zig's anonymous-struct syntax requires. The result was a *valid Zig string
literal* with one extra character in it. Nothing downstream could object: to the
host compiler it is simply a different string. The program served
`.{"status":"ok"}` with a Content-Length of 16, cheerfully, forever.

**What makes this class distinctive is the shape of the input that triggers it.**
The delimiters a lowering pass reacts to — braces, commas, parens, brackets — are
also the most ordinary characters in the payloads a program carries. JSON is the
dense case: it contains nearly all of them at once. So the trigger is not an
exotic edge case reached by a fuzzer. It is the first API route anybody writes.
The defect was maximally reachable and minimally visible at the same time, and
those two properties are *causally linked* — the reason nobody hit it is not that
it was rare, but that hitting it produced no complaint.

The correction to the model: **for text-rewriting passes, the emitted-artifact
tests are not a sufficient net.** They confirm the artifact is well-formed, which
is precisely the thing this class of bug preserves. The only gate that sees it is
running the program and reading its output — which is what a consumer does, and
which is why this was found by pointing a real web framework at a real website
rather than by any test in the corpus.

A second, sharper reading, worth holding separately: *the failure was in the
data, not the control flow.* Every structural check we own — shape, purity,
branch coverage, obligation discharge — reasons about the skeleton of a program.
None of them look at the contents of a literal. That is a whole axis of the
emitted program that nothing currently inspects.

Open question: how many other passes lower Koru surface by walking characters,
and which of them are string-literal-blind in the same way? The one fixed here
was the shared helper both the transform-driven and the direct constructor paths
call, so a single site covered both — but that is a fact about today's call graph,
not a structural guarantee, and [[frag-n-copies-of-one-question]] is the standing
warning that a fix landing in one of N sibling emitters is indistinguishable from
no fix at all.

Related: [[frag-trap-the-sink-not-the-emitter-sites]] — when generated text is
assembled from fragments, the finished line exists in no single source site.
