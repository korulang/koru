---
type: belief
id: frag-obligation-cost-multiplies-with-outcome-arity
provenance: corrected 2026-08-06 hours after it was written — the sixteen hang-ups were not the guarantee's price, they were a `-> u32` on the disposer. A/B measured: void inserts on every arm, `-> u32` gives KORU030.
ts: 2026-08-06
---

# An obligation's ergonomic cost is the number of exits it spans — but the author pays it only where the disposer disqualified itself (belief)

**The arity half stands. The cost half was wrong, and it was wrong the same day
it was written.**

What survives: the pain of an obligation is not its lifetime. A long-lived handle
threaded through a single happy path is free; the same handle spanning an
eight-way branch touches eight exits. That is the axis, and it is the one that
will decide whether an accept loop — many short-lived handles, many exits — is
ergonomic or agony.

What was repudiated: the claim that each of those exits costs the *author* a
written discharge. `440_006` carried sixteen hand-written `close(br): _ |>`
prefixes and I recorded that as "the guarantee seen from the inside." It was the
guarantee seen from behind a signature I had written that morning.

## The mechanism, because the shape of this mistake matters more than the fix

Auto-discharge inserts a disposer only when there is **nothing to bind**
(`auto_discharge_inserter.zig:2742`): the inserter appends a bare call, so a
branch or a bare return needs a binding it cannot invent. `std/bridge:close`
returned the still-held count, which disqualified it — silently, because the
refusal reads *"multiple disposal options or no disposal event"* and I had read
that as "the bridge is unusual", not as "your disposer is not a candidate."

A/B, same three-arm program, one line different: void inserts `close()` on every
arm; `-> u32` produces `KORU030 ... Call: close`. Sixteen author-written hang-ups
became zero, and the emitted output carries fifteen inserted calls — one per
exit, including every failure arm.

## Why the return value was never the honesty it looked like

The count existed to kill an earlier lie — a `dischargeAll` that printed a line,
set a boolean, and released nothing. But **nothing obliges a caller to read a
return value.** `close(br): _` drops it. So the unread count is the same shape as
the boolean it replaced: satisfied bookkeeping over a live resource, one level
further out. Failing to release is not a value; it is a refusal, and it panics
now.

The generalisation, and it is the reusable part: **a disposer that reports is a
disposer that cannot be inserted.** Every diagnostic you add to a cleanup verb's
return trades an automatic guarantee for an advisory one, and the trade is
invisible at the call site — you only see it as a chore you now have to write
everywhere, which reads like the language being strict rather than like a
signature you chose.

## What remains open, and it is not this

The arm COUNT is untouched: sixteen outcomes are still sixteen arms, because
branch coverage is exhaustive and that is separate from who writes the discharge.
Whether a verb should mirror an eight-outcome vocabulary at all is the live
question — narrowing the outcome set is legitimate, and a catch-all arm that
skips the hang-up still is not.

Also open: a disposer cannot currently say "I failed" in a way that keeps it
insertable. A panic branch (`| ?!name`) ought to qualify — unhandled it
synthesizes a `@panic`, so there is no binding to invent — but two things block
it, both measured: a terminal-only panic branch has no way to express success
(`Output = union { could_not_release }`, non-optional), and a panic EFFECT arm
(`! ?!name`) reaches the inserter, which then synthesizes a terminal `|` handler
for it and trips KORU025. So "void, or report nothing" is the real current choice.

Related: [[frag-a-handle-count-is-not-a-capability-check]] — the same subsystem
and nearly the same error one layer down: there a count was mistaken for
enforcement, here a count was mistaken for honesty.
