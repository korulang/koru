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

## Discard is mechanical too: `: _` == `| _ |>`

Lars sharpened the rule 2026-07-12: the migration is *completely mechanical* —
"different syntax and different code generation for the exact same concept."
So a DISCARDED obligation-carrying return behaves identically in both
spellings. The old `| committed _ |> _` branch discard auto-discharged the
dropped payload; therefore `tx.commit(...): _` must auto-discharge the dropped
`<active!>` connection the same way. There is no design fork — a `: _` that
leaks or errors is a codegen bug, not a question.

Root cause + fix (auto_discharge_inserter.zig): the inserter already
synthesized a real name for a `cont.binding == "_"` branch discard (so the
inserted discharge has something to reference), but only checked
`cont.binding` — the bare-return discard lives in the node's
`return_binding`, so `: _` was left as a literal `_`, and the synthesized
`close(conn: _)` leaked an unusable `_` into Zig.
`cloneContinuationWithReturnBinding` + a trigger mirroring the branch case
(fires only when the return carries an obligation; a plain `: _` stays a
genuine discard) materialize `_` → `_auto_N`. Pinned 330_094 (nested discard,
green).

Flow-head continuation-less discharge (CLOSED, 330_095 green): a flow-head
obligation with nothing after it (`~make(): _` / `~make(): h`) is a flow exit
and auto-discharges at the head, exactly like the nested case — Lars ruled the
migration completely mechanical, so a continuation-less head must not leak
(silently for `: _`, as a Zig unused-const for a named bind). The head has no
terminal for the terminator-disposal machinery to fire on, so the inserter
synthesizes one (`giveContinuationlessHeadTerminal`: rename a `_` head bind to
a synthetic, append an explicit `|> _`) and re-runs — the obligation then
discharges through the one existing disposal path, no bespoke head-disposal.
Fired only when `context.hasObligations()` (a real cleanup obligation), so a
non-issuing phantom return discarded at the head is untouched.
