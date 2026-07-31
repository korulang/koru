---
type: belief
id: frag-obligation-enforcement-keys-off-return-binding
provenance: surfaced by challenge 005 regression-board triage; fixed by a candidate-fix contest (330_011 cluster restored)
ts: 2026-07-17
---

# Obligation enforcement keys off `return_binding` — so a transform that drops the bind must not drop the obligation (belief)

Every layer of the auto-discharge / phantom machinery mints and checks an
obligation ONLY when the invocation carries a `return_binding`: the inserter's
head-obligation seeding, its continuation-less terminal synthesis, and the
phantom checker's flow-head threading all gate on `return_binding != null`. An
invocation with no bind mints nothing, inserts nothing, and — the dangerous part
— errors nothing. The resource just leaks, silent, at exit 0.

## Why this bit us

The single-return burn-down ([[frag-single-return-form-is-universal]]) ruled that
a consumer fully discarding a bare-return result (`(): _ |> _`) is "just a bare
call" and dropped the dead discard-binds at ~44 sites. Correct as a surface
ruling — but it silently amputated enforcement for the whole unbound-head class,
because enforcement was coupled to the very bind that was removed. The 330 cluster
(011/025/028/036/037/043/070 — MUST_FAIL obligation tests) all went
`must-fail-passed`: the language's phantom-obligation guarantee, its whole reason
to exist, was switched off for these shapes and nobody noticed for ~5 days. (The
first-floated root — a `run-pre-transforms` pass-ordering shift — was WRONG; the
generated dispatch table had zero `.pre`-stage transforms. The coupling to
`return_binding`, not pass order, was the cause.)

## The rule this establishes

- An unbound flow head whose event carries a `return_phantom` must **materialize
  its implicit discard** (`return_binding = "_"`) before enforcement runs, so the
  discard is visible to the machinery identically to the spelled-out `(): _` form
  (the green pin 330_094 is the reference shape). A transform that drops a bind
  MUST preserve the obligation's visibility, or it silently disables the guarantee.
- `--auto-discharge=disable` and `~[strict]` opt out of **inserting** a discharger,
  never out of the discard being **visible** to enforcement. So they run a
  normalize-only pass (materialize + validate, no insertion), not an early-return
  of the untouched AST. Skipping normalization is how an explicit `open(): f` leak
  passed clean under strict/disable — a [[frag-no-fallbacks]] violation in the
  enforcement path itself.
- Declaration validity is independent of insertion mode: KORU083 (`[!]` must be a
  void event) now also fires under disable/strict, and now catches `[!]` on a
  bare-return `-> T` event (single-return moved non-void-ness out of `branches`
  into the return type).

## The record-field frontier is CLOSED (2026-07-18)

An obligation carried as a **record field** (a return/resume record like
`-> { h: *Handle<owned!>, n }`) is now enforced. Two leaks were plugged:
- The emitter used to paste the phantom into the Zig struct type
  (`struct { h: *Handle<owned!>, n }`) — a raw-Zig compile error. It now strips
  the compile-time-only phantom (`*Handle`), the same lift the input side gets for
  free because its parser splits the phantom into `field.phantom`.
- Enforcement keyed off the whole-value `return_phantom` and never descended.
  It now parses the record return type and seeds a per-field obligation
  (keyed `binding.field`, so multiple per record don't collide).

The ruling that settled the *behavior* (Lars: record fields follow the SAME rules
as event-payload fields, which error when undischarged — 690_024): a return-record
field is NOT auto-dischargeable. Unlike a whole-value bare-return obligation
(330_094, auto-discharged) or a branch-payload field (phantom-checker-tracked, so
an inserted disposer type-checks), a return-record field is invisible to the
phantom checker — an auto-inserted `dispose(r.h)` fails validation. So it presents
no disposal candidate and falls to the "was not discharged" wall
(KORU030 "Call: dispose"), guiding manual discharge. Pinned by 330_096.

Full parity (phantom-checker descent into record-return fields, which would make
the field auto-dischargeable) is deliberately NOT built — the pin rules manual
discharge, and the checker-descent is a larger mirror of the input-side tracking.

## ⚠️ SUPERSEDED 2026-07-31 — the mid-chain frontier closed on the WRONG REMEDY

The section immediately below is kept because its diagnosis was right and its
remedy was not. Read it as history.

`330_097` was minted RED against a real defect: the obligation vanished silently
at exit 0. Two remedies eliminate that leak — **refuse it**, or **auto-discharge
it**. Refusal landed first, the test went green on it, and the pin thereafter
read as a ruling that mid-chain *must* refuse. Nobody compared the two.

The stated ground below — *"an unbound value has no name to `dispose(...)`, so it
is NOT auto-dischargeable"* — **was already false when written.**
`generateSyntheticBinding` and `cloneContinuationWithReturnBinding` had been
minting names for the `: _` case since 2026-07-12, a week earlier, and the
unbound-flow-head rule at the top of this very document says to *materialize the
implicit discard*. Same situation, opposite conclusion, two paragraphs apart.

What genuinely did not exist on 07-19 was the **terminus framing** — established
07-24, in the seam analysis further down — under which a zero-continuation
mid-chain call and a bare flow head are *the same position*. So the two cases
were ruled apart by accident of sequence rather than by any distinction someone
defended. That is the honest account: not carelessness, a ruling made before the
frame existed to see it.

**Ruled by Lars, 2026-07-31**, after the case against was argued at length and
did not survive. Auto-discharge's contract is: an obligation, undischarged by the
author, with exactly one void disposer, gets its disposer inserted. The mid-chain
case meets every clause — and the compiler proved it knew, because its refusal
**named the very call it declined to make** (`Call: bin.close`). A name for the
value is not one of the conditions; requiring one made the definition read
*"settles obligations you did not write down, provided you wrote down a name for
them."*

Every distinction offered in defence of the refusal — authorship, visibility,
library drift — applies identically to the unbound head, which auto-discharges
uncontroversially. The one precedent that looked contrary, the record field, is
refused for a **mechanical** reason that does not transfer: an inserted
`dispose(r.h)` fails phantom validation, so there is genuinely no candidate.

Now: the terminal-unbound path mints a synthetic binding under `mode == .full`
and the ordinary `return_binding` machinery takes over. `330_097` is inverted to
a positive (`disposed n=6`); `330_120` is green.

⛔ **AND IT EXPOSED A HOLE, pinned red as `330_123`.** Under
`--auto-discharge=disable` this shape has **never** been walled — measured both
before and after the change: it compiles clean, exit 0, prints nothing. The
normalize-only pass materializes the discard for an unbound HEAD (which is why
`330_025` walls) and does not reach a zero-continuation mid-chain call. Default
mode was masking it. That violates this document's own standing rule — *disable
opts out of INSERTING, never out of the obligation being VISIBLE to enforcement*
— and it is the next thing to fix here.

## The mid-chain-unbound frontier is CLOSED (2026-07-19) — HISTORY, see above

Mid-chain unbound obligation calls (`make(): h |> bump(h)` where `bump` returns an
obligation and the chain ends unbound) — the continuation-level twin of this root —
are now caught. Enforcement used to mint only when a mid-chain invocation carried a
`return_binding`, so `bump(h)`'s dropped return leaked silently. A TERMINAL
unbound invocation (`cont.continuations.len == 0`) whose event returns a cleanup
obligation now seeds an obligation under a synthetic, unreferencable key. An
unbound value has no name to `dispose(...)`, so — exactly like the record-field
case — it is NOT auto-dischargeable: it presents no disposal candidate and falls to
the "was not discharged" wall (KORU030, error name `return of bump(...)`), guiding
the author to bind and discharge the return. Non-terminal unbound calls are
untouched (branch arms consume the return as payload; sequential prefixes are not
flow exits). Pinned by 330_097.

The two frontiers this belief named are both closed; the `not_auto_dischargeable`
marker (renamed from `from_return_record` when it grew a second origin) is the
shared "no auto-discharge → wall" lever for both.

## The third frontier is CLOSED (2026-07-25): the bound head keeps its obligation across a continuation

Both closed frontiers are about invocations with NO bind. The symmetric case is
still leaking, and it is the ordinary one: a **bound head whose whole-value
obligation is live at exit, where the head has a continuation**.

    app/lantern:light(): lamp                                   # caught, KORU030
    app/lantern:light(): lamp |> std/io:print.ln("in the dark")  # silent leak, exit 0

Appending one void continuation to the caught form switches the wall off. The
continuation mints nothing and never touches `lamp`; the head's own obligation is
simply no longer checked once it is not terminal. Under `--auto-discharge=disable`
this is the normalize-only promise above failing on a shape the earlier fix did
not cover — enforcement is reached, but the head's seeded obligation does not
survive to validation.

Three things this is NOT, each ruled out by a green neighbour:

- **Not the bind form.** Named captures are enforced — the terminal form above is
  caught by name (`Resource 'lamp'`).
- **Not `:` versus `->`.** An obligation produced through a value-return subflow
  is carried correctly across the produce and caught when terminal, then lost to a
  continuation identically. `330_114` pins the `->` surface, `330_113` the `:` one.
- **Not payload shape.** A record-FIELD obligation in exactly this position — bound
  head, continuation present (`make(id: 1): r |> print.ln(r.n)`) — is caught. It
  survives because the record path seeds per-field under `binding.field` with
  `not_auto_dischargeable`, rather than riding the whole-value `return_phantom`.

That last contrast is the lead: the record-field path already does the right thing
in the shape the whole-value path drops.

### Which layer loses it: NEITHER — it is a seam (established 2026-07-24)

The open question above is settled, and the answer is that no layer owns the
check. Both halves are present and both are doing what their comments say:

- The **inserter**, in normalize-only mode (what `--auto-discharge=disable`
  runs), materializes the head binding and then breaks out of the continuation
  walk — "no insertion, no terminator validation … enforcement stays with the
  phantom checker."
- The **phantom checker** seeds the head's `return_binding` obligation into
  `root_context` so the chained continuation can SEE it — which is why a
  discharge LATE in the chain is correctly credited, and the lantern game
  auto-discharges fine. It then validates each continuation and returns. There is
  no post-loop check that `root_context` is empty at flow exit.

So consumption is tracked across the chain and absence is not. Each layer
delegates the exit check to the other.

A branch arm escapes this because `validateContinuation` performs a terminal
validation of the ARM's own scope. The flow head's `root_context` has no
equivalent. That is the whole asymmetry, and it is Lars's reading: this is a
SCOPING gap, not a binding-form gap. `330_115` is the control — same obligation,
same continuation, delivered as `| lit lamp`, caught — and it must stay green
through any fix, or the hole moved rather than closed.

### The check already exists and is structurally unreachable

The working spelling hands over the fix. `reportLeaksAtHardTerminal` performs
precisely the needed check — "a hard terminal permits no escape, so the check
reduces to: anything uncleaned, outer-scope excepted, is a KORU030 leak" — and
its comment records that it was added for this very class, so that "the
enforcement side sees every flow exit the insertion side sees."

It is called under `if (exit_node == .terminal)`. And `.terminal` is `|> _`,
which **`KORU010` permits only as a branch-handler body**: "'_' has meaning only
as `| branch [binding] |> _`." So the guard is not merely unsatisfied for a
top-level `:` chain — it is unsatisfiable. The exit check can only ever fire
inside a branch arm, which is the entire reason the two spellings diverge.

The fix was therefore not new machinery. In the void/bare-return path, a step
that resolves to a known invocation validated its nested continuations and
returned; it now first asks whether there ARE any, and with none treats that as
the flow exit and runs `reportLeaksAtHardTerminal` against the live context.
Same function, reached by a satisfiable condition.

The feared complication did not materialise. `cont.continuations.len == 0`
cannot by itself distinguish a real exit from a sequential-prefix sibling, and
capture-at-flow-head lowers to exactly such siblings — so the prediction was
that capture and scope tests would false-positive. The full suite says
otherwise: zero regressions attributable to the change. Prefix siblings inherit
a fresh context from the root rather than accumulating into the final sibling
here, so the naive exit test holds. If a future capture form breaks this, the
inserter's `isSequentialPrefix` is the notion to port.

Pinned by `330_113` (`:` bind), `330_114` (`->` produce across a subflow
boundary), with `330_115` as the branch-arm control that must stay green — a
fix that reddens it moved the hole instead of closing it.

Two spellings of the same program must type the same; the inserter's own
head-seeding comment already asserted that as the intent, and now they do.

Default auto-discharge masks all of it — with insertion on, the compiler emits the
missing discharger for these exact programs and they are correct. The wall is only
observable under `disable`/`~[strict]`, which is why this sat behind the two
frontiers that were found first.
