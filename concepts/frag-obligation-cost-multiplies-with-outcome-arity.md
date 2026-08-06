---
type: belief
id: frag-obligation-cost-multiplies-with-outcome-arity
provenance: 440_006, 2026-08-06 — a two-turn bridge conversation over an 8-branch run verb carries sixteen `close` calls, and the compiler refuses any arm that omits one (KORU030)
ts: 2026-08-06
---

# An obligation's ergonomic cost is the product of its lifetime and the outcome arity it spans (belief)

`std/bridge:create` mints `<session!>`; only `close` discharges it. `std/bridge:run`
mirrors `std/runtime:run`'s eight outcomes, because forwarding an existing
vocabulary invents nothing. Those two reasonable decisions multiply: a two-turn
conversation is sixteen arms, and **every one of them must hang up** or the
program does not compile.

That is the guarantee working exactly as designed, seen from the inside for the
first time. It is also the first measurement anyone has on the standing question
of what the **unit of obligation** should be — the one flagged as deciding
"whether an accept loop is ergonomic or agony." The answer this instance offers:
the pain is not in the obligation's lifetime, it is in how many exits cross it.
A long-lived handle threaded through a single happy path is free; the same
handle spanning an eight-way branch costs eight discharges per turn.

## Why the obvious relief is a trap

The pressure this creates points straight at a catch-all arm that skips the
hang-up, or a discharge that fires implicitly at some scope end. Both are the
same move: making the common case cheap by making the guarantee optional, which
is the fallback pattern wearing an ergonomics justification. The failure arms are
exactly where a session most needs hanging up — a turn that errored is the turn
most likely to be abandoned.

The legitimate reliefs do not weaken the refusal. Narrow the outcome set so fewer
arms exist (a bridge verb need not mirror eight outcomes just because the tor
beneath it has them). Or let one arm *route* to a shared discharge rather than
each writing its own — a shape question, not a strength question.

## What would correct this

A spelling that collapses N arms to one hang-up without making any arm able to
skip it. If that exists, the cost was never the arity — it was the absence of a
way to say "all of these, then close", and this belief is measuring a missing
construct rather than a structural price.

Related: [[frag-a-handle-count-is-not-a-capability-check]] — same subsystem, and
the reason the guarantee is worth this price: the compile-time refusal is the
part that was always real.
