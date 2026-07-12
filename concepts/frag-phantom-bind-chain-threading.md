---
type: belief
id: frag-phantom-bind-chain-threading
provenance: introduced with the phantom bind-chain threading fix — Lars-ruled 2026-07-12 ("exactly the same for these flat phantom binds as with sub flows")
ts: 2026-07-12
---

# Phantom obligations thread across CHAINED flat bind-form consumers (belief)

Migrating a lone continuation branch on a phantom-returning event
(`| tx t |> …`) to the single-return bind form (`tx.begin(conn: c): t |> …`)
must carry the re-issued `<state!>` obligation across EVERY link of the
chain — identically to a single bind and to a loop back-edge. Lars ruled it
2026-07-12: "it needs to be exactly the same for these flat phantom binds as
with sub flows." This is the phantom-checker corollary of
[[frag-single-return-form-is-universal]]: if the bare-return form is
universal, its obligation must thread everywhere the branch-payload
obligation used to.

The discriminator was never "subflow vs flat" — that was a misread of the
green corpus. The green phantom tests (330_074/082/085) happen to thread
through a loop back-edge OR a single top-level bind
(`spin(): hf |> dispose(h: hf)`), and both work. The untested/broken shape
was specifically a **chained** flat bind: `make(): h |> t1(h): a |> fin(h: a)`
lost the obligation from the first chained link onward. A single flat bind
already worked.

Root cause (phantom_semantic_checker.zig): only the flow HEAD registered its
bare-return bind (`recordBareReturnBind` at the flow head, ~line 1056), and a
named branch's nested continuations registered theirs. The two bare-return
HEAD-chain paths (the 0-branch void head and the empty-branch void chain)
resolved nested continuations against the step's event but never recorded the
step invocation's own `return_binding` phantom — so an intermediate step's
bind (`t1(h): a`) reached its consumer with no tracked obligation (spurious
KORU030 on `a`, cascading to every downstream link). Fix: `recordBareReturnBind`
factored out and called in both head-chain paths before recursing.

Pinned: 330_093 (flat 3-link phantom chain, MUST_RUN). Unblocks the 2104
transaction cluster and the wider KORU030 burn-down class, whose consumers
convert branch-form → bind-form once the compiler threads the obligation.
Relates to [[frag-comptime-obligation-discipline]] and the escape-driven
stack-allocation reasoning (obligation = lifetime proof).
