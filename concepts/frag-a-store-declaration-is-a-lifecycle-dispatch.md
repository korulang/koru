---
type: belief
id: frag-a-store-declaration-is-a-lifecycle-dispatch
provenance: probed while designing a pump aggregator — asked what a store says about an arm outside its vocabulary
ts: 2026-08-01
---

# A store declaration is a general lifecycle dispatch, not a `! discharge` slot (belief)

`! discharge` reads like a bespoke escape hatch bolted onto `std/store:new` for
the one case the auto-discharger cannot settle. It is not. The declaration site
is an interceptor dispatch over a **vocabulary** — `discharge`, `inserted`,
`removed`, `updated` — and a name outside it is refused with a message that
prints the vocabulary back to the author. So the site is designed to grow: the
cost of a new lifecycle arm is a name in an existing dispatch plus its emitter,
not a new declaration form and not a parser change.

This is the update that matters for anything wanting to hook a store's rows.
A pump arm — "here is how a row ADVANCES", the sibling of "here is how a row
ENDS" — has been reading as new language surface. It is a fifth interceptor.

The corollary is the trap, and it is not the one it first looks like. An
interceptor's body is **silent**: an arm whose body is a single `std/io:print.ln`
compiles, runs, prints nothing, and reports nothing. The first reading — "the
arm never fires" — is wrong. It fires; the store calls the handler, and the
handler is emitted. What does not happen is the body's **comptime transform**:
`print.ln` is `~[keyword|comptime|transform]`, a call site rewritten into inline
Zig, and inside a synthesized interceptor body it survives unexpanded as a
`print_impl` call carrying the raw template string, whose result is discarded.
Both `inserted` and `removed` behave this way, so it is the class and not a
single arm. 690_236 pins it.

That places the defect where it belongs: this is the store's instance of
**authored surface is normalized, synthesized surface never is** — an
interceptor body is cloned into a synthesized item and never re-enters the
normalization that would expand it. The store did not grow its own bug; it
inherited a general one, and it is the first place where the consequence is
*silence* rather than a diagnostic.

So the standing open question — should transform output re-enter normalization?
— now has a case that answers it. A lifecycle arm is authored surface by every
measure the author can see: they wrote it, at a declaration, in Koru. If the
body a user writes cannot run the transforms that same body runs one line
higher, the declaration site is offering surface it cannot honour.

This is load-bearing beyond the four names. Any future interceptor — a pump's
"how a row ADVANCES", the sibling of "how a row ENDS" — is born into the same
lowering, and would be born silent. The vocabulary cannot safely grow until the
bodies run.

Open question: the vocabulary is closed and the refusal calls the rest "a later
slice", so the design anticipates growth without saying what governs it. Nothing
states which lifecycle moments a store owes an arm for, so each addition is
argued on its own. A rule — every transition a row can make is nameable, or
these four are the transitions and the list is complete — has never been
written down.
