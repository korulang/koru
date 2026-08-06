---
type: belief
id: frag-per-call-template-variants-are-the-declarers-obligation
provenance: closing cluster D_template_variant against the measured JS baseline — KORU121 named 12 distinct constructs, only one of which lives in koru_std
ts: 2026-08-06
tags: [js-parity, templates, per-call, corpus]
---

# A per-call template's target variants are an obligation on WHOEVER DECLARES the construct — the stdlib is only the most visible declarer (belief)

A per-call template (`~proc <name>|template|<lang>`) is spliced inline at the
call site, **upstream of the emitter's variant pick**. That is why
`selectPerCallTemplateProc` must choose by BUILD LANGUAGE rather than let the
emitter choose later, and why a construct with no `|template|<build_lang>`
sibling is KORU121 rather than a silent `|zig`-body leak onto a JS target.

The consequence nobody had drawn: **the set of per-call template constructs a
program uses is not bounded by koru_std.** Any `.kz` file may declare one, and
each declaration carries a per-target obligation that only its own author can
discharge — the body is opaque host text, so no compiler pass can translate
`std.debug.print("n={{ n }}\n", .{})` into a `console.log`. KORU121's own
fix-hint says exactly this and says it in the right place: *"add `~proc
<name>|template|<lang>` next to the existing variants in the construct's
source"*. For a construct declared in a test, the construct's source **is the
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

Open question: whether the corpus WANTS eleven per-test JS variants. Each one
makes its test genuinely cross-target — the template engine's own features
(`{{ arg }}`, `{% if %}` comparison, `{% for %}` over `effects[…]`, `.continue`
hand-off) get exercised on both emitters, which is strictly more coverage than
today. But it also doubles every future edit to those bodies, and a test whose
point is the *engine* may not want to pin two host languages to do it. The
alternative — a `|template|any` tag for a body that is provably host-neutral —
does not exist and may not be expressible, since these bodies are exactly the
ones that are NOT neutral. Unresolved at the time of writing — the `~cond` half
is landed, the eleven are not yet attempted.
