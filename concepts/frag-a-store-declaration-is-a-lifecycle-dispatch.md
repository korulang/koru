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
Zig, and inside such a body it survives unexpanded as a call carrying the raw
template string, whose result is discarded.

And the arms **disagree with each other**, which is the finding. `! discharge`
expands its body, interpolation and all; `! inserted` and `! removed`, on the
same declaration, do not. So this is not "synthesized bodies don't normalize" as
a flat rule — the declaration site already knows how to run an arm body, and two
of its arms don't get it. 690_236 pins the asymmetry, control in the same file.

The two paths differ in how the body is appended. `! discharge` rides the
teardown flow as an ordinary flow item with no `impl_of`. The lifecycle arms go
through a shared emitter that appends a `retain`ed event declaration plus a flow
that IS its implementation — `impl_of` set.

But that is a correlation and not yet the cause, because the arm path is **not
simply broken**. 690_016 is green, and its `! inserted` body is a comptime
transform too — a store write. So a transform does expand inside `! inserted`.
What fails is a particular transform in that position, and what survives is
another. The defect is an interaction between the arm's lowering and something
about the transform that meets it, and until that something is named, any patch
is a guess with a green test in front of it.

This is the third time the scope has shrunk under measurement: from "the
interceptor class", to "inserted/removed but not discharge", to "some transforms
but not others, in inserted". Each step came from running a control rather than
from reading more code, and each previous claim would have justified a different
and wrong fix.

So this stays adjacent to **authored surface is normalized, synthesized surface
never is** without collapsing into it — that shape predicts far more failure
than is observed. What it is: the first place where a store declaration accepts
surface it silently does not run, and the pin for it (690_236) carries a control
that passes in the same file.

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
