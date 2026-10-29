---
type: belief
id: frag-a-head-label-needs-a-runtime-call
provenance: emitbug session 2026-10-29 — `#repl std/io:print(...)` shape-checked clean, then died in Zig on `continue :repl` against a label block the consumed transform never emitted
ts: 2026-10-29
tags: [koru, labels, fold, transforms, diagnostics, KORU211]
---

# A `#L` anchor on a flow head requires a runtime call — `pre_label` is lifted off the invocation, so a transform head can never carry it (belief)

A label fold's re-dispatch target is the anchored call's *runtime*
invocation. At flow-head position the parser lifts `#L` onto
`flow.pre_label`, OFF the invocation — the site a transform receives
contains no label, so a keyword/comptime/transform head call is consumed at
compile time with no way to carry the anchor into its rewrite. The emitted
program then holds `continue :L` jumps against a `L:` block that was never
emitted, and the jump's args get declared with the transform's AST-level
parameter types (`Expression` does not exist at runtime). Every such
program is a lie the checker can see: KORU211 refuses it in the frontend
flow pass, reported at `flow.location` — the `#L` head line.

The ruling names a *compile-time surface*, not "transform" alone:
`[transform]`, `[keyword]`, `[declaration]`, `[norun]`, and `[comptime]`
without `[runtime]` all mean no runtime invocation exists to wrap. A
dual-mode `[comptime|runtime]` decl does materialize a call and stays
legal.

**Mid-chain `|> #L inv` is not covered and must not be.** There the label
and invocation travel together inside the transform's site — a transform
that honors the anchor re-emits it on its generated runtime call
(`ring.dequeue`'s `#consume` fold, `supervised`'s labeled retry fold are
pinned working shapes). Whether a mid-chain transform honors or drops the
label is that transform's contract, not a checkable rule — the head case is
different precisely because lifting makes honoring impossible.

Sibling of [[frag-a-fold-that-cannot-exit-is-refused]] (KORU206, `.all`
mode): that wall asks whether the fold's arms can exit; this one asks
whether the fold's anchor exists at all. Related tension with
[[frag-a-site-replacing-transform-owns-the-chain-tail]]: a transform owns
what arrives in its site — and `pre_label` never arrives.
