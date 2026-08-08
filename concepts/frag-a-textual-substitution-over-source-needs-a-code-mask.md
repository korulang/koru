---
type: belief
id: frag-a-textual-substitution-over-source-needs-a-code-mask
provenance: 690_267 — a rule arm's row rewrite corrupted a string literal, the second site of the same defect after 230_016
ts: 2026-08-08
---

# A textual substitution over source needs a code/text mask, and having one in the file is not having one at the site (belief)

Koru rewrites source text in several places: the visitor emitter renames
identifiers that collide, the store rewrites `<row>.<column>` into a cell read,
transforms splice rendered bodies. Each is a find-and-replace over a string that
is *mostly* code and *partly* not.

Twice now the same defect has shipped. On 2026-08-07 the visitor emitter
rewrote user identifiers inside string literals, so a message reading
`"a count above zero"` shipped as `"a __koru_event_input.count above zero"` —
compiled, ran, no complaint (230_016). On 2026-08-08 the store's rule-arm
rewrite did the same at a different site: a literal `"e.label is a column"`
became a Zig cell read stored as the row's text, silent on the JS lane and an
unreadable Zig error on the other (690_267).

**The second one is the instructive one, because the mask was already there.**
`entityRefs` computes `ast.expressionMask` at its head. It consulted it in
exactly one branch — the bare identity binding — and not in the
`<bind>.<column>` branch, which is the shape every rule arm uses. So the
protection existed, was paid for, and covered the rare case while the common
case went bare. Reading the function top-to-bottom shows a mask being computed
and looks correct.

So the belief has two halves. The first is ordinary: **any substitution over
source gets a code/text mask, never a special case per known-bad input.** The
second is the one that costs time: **a mechanism being present in a file is not
evidence it is applied at the site that matters.** Grep for the mask and you
find it; grep for the substitution and you find several, and only some consult
it. The check is per-substitution, not per-file.

The subtlety that makes this more than "skip strings": **interpolation inside a
literal IS expression context.** `print.ln("v={{ e.v:d }}")` reads a column
from within a string and must keep working. A mask that skipped literals
wholesale would break every rule arm that prints — and would have looked like
the fix, passed casual inspection, and failed a different set of tests. Both
pins carry that control in the same file as the defect for exactly that reason.

Open: nothing enumerates the substitution sites. Three are known
(visitor_emitter, store's entityRefs, store's bindStrip); there is no list, so
the next one is found the way these two were — by a consumer shipping text
nobody wrote.
