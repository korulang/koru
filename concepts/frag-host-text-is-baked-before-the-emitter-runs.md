---
type: belief
id: frag-host-text-is-baked-before-the-emitter-runs
provenance: cluster D_template_variant — two Zig-text-on-a-JS-build defects found in src/template_processor.zig, a pass that runs before any emitter
ts: 2026-08-06
tags: [js-parity, templates, measurement]
---

# Not every target gap is in an emitter — per-call templates bake host text at Stage C, upstream of emitter selection (belief)

The JS-parity work was framed around the emitter. The measuring instrument says
so in its own vocabulary: `scripts/js-parity-map.mjs` sorts the corpus into
buckets and `js-scan --bucket emitter` selects "the tests whose failures can only
be the emitter's". That framing bought the first real baseline and it found the
dominant gap ([[frag-js-emitter-assumes-every-event-has-a-proc]]). It also has a
blind spot, and the blind spot has a name.

**A per-call template is rendered at Stage C and SPLICED INLINE at the call site,
before the emitter picks a target.** That is why
`template_processor.selectPerCallTemplateProc` has to choose `|zig` vs `|js` by
BUILD LANGUAGE itself, and why KORU121 exists at all — there is no later moment
at which the choice could be made. The same is true one level down: wherever that
render produces text that must be *spelled* in the host, the spelling decision is
final at Stage C. No emitter fix can reach it.

Two such renders existed, and both got the language wrong on a JS build:

- `{{ binds }}` — `cond`'s binder preamble. Emitted Zig anon-struct syntax
  (`.{ .value = n, }`), `: T` representation annotations, and `_ = &v;`
  unused-suppression. The last of those does not even parse as JS.
- the `~if(<optional arm>)` presence test. Emitted `@hasDecl(__H, "<arm>")`.
  `__H` is Zig's comptime handler TYPE param and has no JS existence at all.

Both are now keyed on `HostLang` in `template_processor.zig`, whose doc comment
carries the load-bearing claim: **that set is exactly two.** The claim is there to
be falsified cheaply by the next person, which is the only thing that makes a
"we found them all" statement worth writing.

**What generalises is where to look, and why nobody looked there.** Both defects
were single-line renders that ignored an argument the enclosing function already
had in scope — `build_lang` was threaded through `renderTemplateInvocation` the
whole time. Neither was hard; both were invisible, because "the JS target is
immature" and "the JS emitter is immature" had been allowed to mean the same
thing. A bucket named `emitter` quietly asserts that the emitter is where the
answer is, and a name that asserts its own conclusion stops being a question. The
honest reading of the parity map is narrower than its label: it selects tests
whose failures are *not the stdlib's and not the fixture's*, which is not the
same as *the emitter's*.

The corroborating detail is that these two were found by walking a failure family
to its root rather than by reading the histogram. The histogram grouped on
diagnostic string; both of these sat behind a diagnostic (KORU121, then
NoJsProcBody) belonging to a different layer, so no amount of sorting the
baseline would have surfaced them. Cf. the same shape one level up in
[[frag-per-call-template-variants-are-the-declarers-obligation]]: clustering on
the symptom conflates causes that recommend opposite plans.

**The falsification signal is quieter than it looks (added same day).** The
cluster-A worktree reports that js_emitter is growing a host-BUILTIN translation
on the way out — `@mod`, `@rem`, `@divTrunc`, `@as`, `@intCast` rewritten to JS
twins as rendered template text is emitted. That is the emitter cleaning up after
a target-blind path rather than a third render site, so the count of two stands.
But it changes what a green JS test proves: a per-call template can ship raw Zig
integer builtins in its condition text and still run correctly, so a genuine
third host-text site may produce **no visible symptom at all**. The `HostLang`
doc comment now says this out loud, because a falsifiable claim whose
falsification is silently absorbed downstream has stopped being falsifiable, and
a reader who takes "the JS tests are green" as evidence the count is still two
would be reasoning from a repaired symptom. (Reported by GapASubflowImpl; the
code was unmerged when this was written, so it is an inbound claim, not something
verified in this tree.)

**Debt, declared as debt.** The check this wants is "every pre-emitter pass that
emits host syntax consults the build language", and it is not written, because it
is not obviously mechanisable — host syntax in a string literal is not
syntactically distinguishable from any other string literal, so a grep-shaped
wall would be mostly false positives. Until someone finds the honest predicate,
the residue is the `HostLang` doc comment and this fragment, and both are prose
standing in for a wall that should exist. The unit tests on
`template_processor_tests` pin the two renders that DO exist on both hosts; they
cannot pin the absence of a third.

Open question, and it is the one that decides whether this stays prose: is
"emits host text" a property that could be made structural — e.g. a distinct
return type for host-language strings, so that producing one without a
`HostLang` in hand does not compile? That would move the belief into the type
system and let this fragment shrink to a pointer.
