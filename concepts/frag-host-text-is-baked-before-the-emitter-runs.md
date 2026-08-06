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

**The falsification signal has one bounded blind spot — and knowing the bound is
the whole difference (added same day, then corrected the same hour).** js_emitter
translates Zig host BUILTINS out of rendered template text on the way to JS
(`Emitter.writeHostText` -> `writeHostBuiltin`, js-gap-a 31f3aa2a, unmerged when
this was written). That is the emitter cleaning up after a target-blind path
rather than a third render site, so the count of two stands.

My first reading of that was too pessimistic, and the correction is the part
worth keeping. I wrote that a green JS test had stopped being evidence at all —
that the falsification was "silently absorbed downstream". It is absorbed over an
**exhaustive, committed list** (the identity casts, the four division/modulo
forms, `@min`/`@max`/`@abs`/`@sqrt`) and **nowhere else**: any other `@name(`
reaching the JS emitter is REFUSED with `UnsupportedConstruct`, not passed
through. So a third host-text site emitting an unmodelled builtin fails LOUDLY at
compile time. Green is weak evidence over exactly that list and sound everywhere
else.

"The signal is muffled" and "the signal is muffled over sixteen named builtins
and loud otherwise" recommend different amounts of paranoia, and only the second
is actionable. A caveat stated at the wrong scope is its own kind of drift: it
reads as rigour while making the claim it guards unusable, and it survives longer
than a plain error because it sounds careful. I had the first version committed
before the peer sent the spelling; the lesson is that a limit on a claim needs the
same grounding as the claim.

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
