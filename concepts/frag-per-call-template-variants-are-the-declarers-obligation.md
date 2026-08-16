---
type: belief
id: frag-per-call-template-variants-are-the-declarers-obligation
provenance: closing cluster D_template_variant against the measured JS baseline — KORU121 named 12 distinct constructs, only one of which lives in koru_std
ts: 2026-08-06
tags: [js-parity, templates, per-call, corpus]
---

# A per-call template's target variants are an obligation on WHOEVER DECLARES the construct — the stdlib is only the most visible declarer (belief)

A per-call template (`~[template]proc <name>|<lang>`) is spliced inline at the
call site, **upstream of the emitter's variant pick**. That is why
`selectPerCallTemplateProc` must choose by BUILD LANGUAGE rather than let the
emitter choose later, and why a construct with no `[template]` proc for the
build lang is KORU121 rather than a silent `|zig`-body leak onto a JS target.

The consequence nobody had drawn: **the set of per-call template constructs a
program uses is not bounded by koru_std.** Any `.kz` file may declare one, and
each declaration carries a per-target obligation that only its own author can
discharge — the body is opaque host text, so no compiler pass can translate
`std.debug.print("n={{ n }}\n", .{})` into a `console.log`. KORU121's own
fix-hint says exactly this and says it in the right place: *"add
`~[template]proc <name>|<lang>` next to the existing variants in the
construct's source"*. For a construct declared in a test, the construct's source **is the
test**.

Cluster `D_template_variant` was scoped as one gap — sixteen tests, one missing
variant in `koru_std/control.kz`. Read against the actual diagnostic output it
is two families that share a symptom and nothing else:

- **`~cond`, in koru_std.** One variant closes five call sites at once, because
  the construct is shared. This is the shape the cluster was named for, and the
  shape people expect: fix the library, the corpus moves.
- **Eleven constructs the TEST FILES declare themselves** (`show`, `maybe`,
  `pick`, `probe`, `probe3`, `probe-cmp`, `ping`, `count-to`, `each-in`, `loop`,
  `shout`). Each is used exactly once, by the test that declares it. There is no
  library fix. The corpus is *itself* a declarer, and eleven of its files owe a
  JS variant.

**The load-bearing half is what this says about counting.** A cluster built by
grouping on the diagnostic string groups on the SYMPTOM. KORU121 is one error
code with one message, so sixteen tests looked like one gap worth one fix —
and the honest ratio is 5 tests per unit of library work against 1 test per
unit of corpus work. A frontier report that says "16, one fix" and a frontier
report that says "5 by one fix, 11 by eleven" describe the same measurement and
recommend opposite plans. Error-code clustering is a cheap and genuinely useful
first cut, but it silently conflates *one construct used many times* with *many
constructs used once*, and the distinction is the entire economics.

The narrower engineering ruling, from the `~cond` half: where a construct's two
lowerings differ only in host DECLARATION syntax, the divergence belongs in the
one place that renders that text (here `{{ binds }}`, keyed on build language by
`BinderHost` in `template_processor.zig`) and **not** in a second template body
or a second context key. The two `cond|template|<lang>` bodies are byte-identical
because the dispatch cascade genuinely is one construct in both languages; a
`binds`/`binds_js` pair would have re-created the two-homes-for-one-rule shape
that `~for`/`scan` was deliberately converged to kill — kin to
[[frag-a-fix-lands-in-one-lowering-path]] and
[[frag-two-lowerings-share-one-contract]].

## What writing the eleven actually taught (2026-08-06, same day)

Nine of the eleven were written and verified end to end — emitted JS run under
node, diffed against the untouched `expected.txt`. Two were **refused**, and the
refusal is the finding.

**A template-facing context key is itself a per-target surface.** The engine's
context is not one vocabulary that every target can read; some keys have a
lowering on only one target. `{{ h.inlined_link[scope] }}` mints a marker both
emitters resolve. `{{ h.link }}` — the isolated-Handlers-**fn**-call flavour —
has a Zig lowering (the emitter emits the Handlers struct plus an in-scope alias
at the splice site) and **no JS lowering at all**: js_emitter binds
`const each = H.each` inside the handler and never into the SPLICED flow scope,
so a JS variant using it renders a bare `each(__i)` and dies `ReferenceError`.

The corroborating count: `h.link` has **zero consumers in koru_std.** Every
shipping stdlib template — `~for`, `types:fields-of` — uses
`inlined_link[scope]`. Its only consumers are the three template-engine tests
that exist to demonstrate the engine (250_004/005/006). So `h.link` is not a
neglected surface with users waiting; it is a surface the library never adopted,
which is exactly why nobody noticed it is single-target.

**The ruling that follows: do not port a variant onto a target whose mechanism
it cannot express.** 250_004 and 250_006 state `{{ h.link }}` as their pin in
prose. Writing them a JS sibling in the *other* flavour would have made one
construct's two variants pin two different mechanisms and quietly redefined a
deliberate pin; writing them a JS sibling in `h.link` would have committed a
lowering that is guaranteed to throw. Both are worse than the honest KORU121,
which at least says truthfully "this construct has no variant for this target."
A degraded lowering shipped as a lowering is the failure mode; the missing one
is only a gap. Where the mechanism divergence is *incidental* rather than the
pin — 400_101, whose stated point is the templated iterable and whose handler
call is machinery around it — porting to the target's own mechanism is right,
and that one is green.

So the original open question is answered, with a boundary: a test SHOULD carry
per-target variants when what it pins is target-neutral (engine behaviour: `{{
arg }}` substitution, `{% if %}` comparison, presence, `{% else %}`), and MUST
NOT when what it pins is the target-specific mechanism itself. The `|template|any`
idea stays unbuilt and now looks wrong: these bodies are precisely the
non-neutral ones, and the two refusals show the engine surface is not uniformly
available either.

Still open, and it is a measurement question: whether `h.link` should get a JS
lowering or be **retired** in favour of `inlined_link[scope]`. Zero library
consumers argues for retiring it and rewriting the three engine tests. Nobody has
asked what the isolated-fn flavour buys that the splice flavour does not, which
is the question that decides it.

## The spelling move (2026-08-16, docs/TEMPLATE_SPELLING.md)

The `|template|` VARIANT spelling was a category error — a declaration KIND
lives in the bracket, the bar means "which build/impl" only. The construct is
now `~[template]proc <name>|<lang>`. The belief here is untouched: the
per-target obligation on the declarer, the upstream build-language selection,
and KORU121 all survive verbatim — only the surface being spelled changed.
The `|template(once)|` per-decl mode had zero users anywhere and was removed
with its three regression pins rather than re-spelled.
