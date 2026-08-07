---
type: belief
id: frag-a-mode-label-is-untested-until-a-rewrite-depends-on-it
provenance: mangling JS reserved words 2026-08-07 — one new rewrite in the shared expression pass broke 390_020, and the defect was a mode argument written weeks earlier that had been wrong the whole time and cost nothing
ts: 2026-08-07
---

# A parameter that nothing reads is not configuration, it is an unverified claim (belief)

`lowerKoruExpr` takes a mode: `koru_expr` for text a user wrote in a Koru
expression slot, `host_text` for text a template already rendered into the host's
language. Exactly one rewrite consulted it — `++`, which is Koru's concatenation
in one mode and JavaScript's increment in the other. Every other rewrite ran in
both.

So when `std/kernel` passed `.koru_expr` for an op body, the label was **already
wrong** — an op body is `const dx = k.other.x - k.x; …`, a statement sequence in
host syntax, not an expression. It named the text incorrectly and nothing
noticed, because the one rewrite that read the mode did not care: an op body has
no `++` in it.

Then a second rewrite started reading the same mode. Renaming a JavaScript
reserved word is sound only where every identifier is a reference, so it keyed on
`koru_expr` — and turned `const dx = …` into `const$ dx = …`. The regression was
instant and loud, and the thing that broke was not the new code.

**The rewrite did not introduce the defect. It was the first thing to depend on
an answer that had never been checked.**

## Why this class hides so well

A mode argument looks like configuration, and configuration looks inert. It is
actually a **claim about the text** — "this is an expression" — made by a caller,
consumed by nobody, and therefore never contradicted. Every such argument is a
small unverified assertion sitting in the tree, and the ones that are wrong are
indistinguishable from the ones that are right until something reads them.

That makes the *cost* of a wrong label arbitrarily deferred and its *blame*
misdirected: the commit that fails is the one that finally asked.

## What follows

- **Adding a rewrite to a shared pass retroactively tests every call site's
  mode.** Expect fallout proportional to how long the parameter went unread, and
  read it as pre-existing, not as damage the new rewrite did.
- **A mode should name what may be DONE to the text, or it should be split until
  it does.** `koru_expr` was carrying two questions — may `++` be rewritten, and
  is every identifier a reference — that have different answers for a kernel op
  body. One name for two questions is fine right up until the answers diverge,
  and there is no warning at the moment they do. The split is
  `koru_expr` / `koru_body` / `host_text`.
- **The blast radius is every caller, so enumerate them before adding the
  rewrite, not after.** There were three, and the third was not even reached.

## The other half: one home is not every door

The same session found `std/io` splicing `{{ … }}` interpolations into JavaScript
without going through the shared pass at all — so an interpolation naming
`a and b`, or `@as(i64, x)`, reached node unlowered. Nothing had noticed, because
no test interpolates one.

This matters because the pass had been given a single home **specifically** so
transforms could reach it, and that was recorded as done. It was true that the
home was single. It was not true that every transform reached it, and the two
claims are easy to state as one. Giving a pass one home is checkable in an
afternoon; connecting every door is an enumeration nobody performed, and its
absence looks exactly like completion.

## Open

Whether the three callers should be *forced* to answer rather than defaulting.
Zig has no required-argument mechanism beyond making the parameter non-optional,
which it already is — the label was supplied, considered, and wrong. A wall that
catches this would have to compare the label against the text's actual shape,
which is the same undecidable question the mode exists to answer. Possibly the
honest answer is that mode labels want a positive control per caller — one test
per call site whose whole job is that the mode is right — and that this is the
`frag-a-check-that-cannot-match-reports-clean` discipline applied to arguments
instead of to greps.
