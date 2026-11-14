---
type: belief
id: frag-an-atom-with-an-argument-is-still-an-atom
provenance: sym.rel band 2 — g(name,arg) application (615_076), measured across the SNode/derive/canon diff
ts: 2026-11-16
tags: [sym, rel, band-2, substitution, snode, canon]
---

# `g(name)` IS `g(name, x)` — arguments are an optional payload on the atom, not a new kind (belief)

Band-2 `g(name, arg)` looked like a new node kind (`gapp`). It is not:
the bare generator atom already *meant* "applied to x" — `atom >= 5` is
`f(x)` by definition, so the explicit form is the same node with an
`garg: ?*SNode` payload. Choosing the payload over the kind was not a
shortcut, it was the honest encoding — and it avoided a measured blast
radius: 19 `switch (n.kind)` sites across 10 part files, nearly all
exhaustive, would each have grown a refuse arm for a node those lanes
can never see (garg'd atoms only exist under greg parses).

The non-obvious semantic: **substituting x:=u into a law must LIFT bare
generator atoms**. `D sin = g(cos)` stores `atom cos` meaning cos(x);
evaluated at u it is cos(u) — `substX` turns `atom(f)` into `atom(f)
with garg u`, not a bare `atom(f)`. Miss that and `D sin(u)` comes out
`cos(x)·u'` — silently wrong, not refused. The applied case recurses
instead (`g(f, v)` → `g(f, v[x:=u])`).

Two edges pinned in 615_076: `g(f, x)` normalizes back to the bare atom
(the fold makes the implicit-x identity canonical), and const arguments
derive to `0e0` through the ordinary `u' = 0` path — no special case.

**The sort-key trap**: `sortKids` orders terms by `canonOf` strings *with
no registry*, where applied atoms used to render `g#0` — arg-blind. Two
different applications of one generator then shared a key under an
unstable sort, and any canon-equality check would conflate them. The
`g#` fallback now renders `g#i(arg)` — a canon key must carry everything
the node carries, because the fallback's job is exactly the case where
names are unavailable.

Same-shape boundary: `.rsum` refuses inside `substX` — `aux` embeds
x-polynomials as *text*, so substitution would have to edit a string it
cannot see. Laws carrying `rsum` atoms error `bad` rather than half-
substituting.

Open: value-laws (`exp(x+y)=exp(x)exp(y)` — functional equations, not
D-laws) need a second law slot per generator; that registry spelling is
Lars's question. `substX` is the engine a future `~laws` `rewrite` kind
would delegate to — it was built inside rel because the laws live there.
