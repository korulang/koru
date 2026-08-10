---
type: belief
id: frag-rust-proves-correct-use-not-use-at-all
provenance: measured 2026-08-09 by compiling and running all 23 cases of tests/regression/900_EXAMPLES_SHOWCASE/910_LANGUAGE_SHOOTOUT/2104_* in Rust as well as Koru; verdicts carry verbatim rustc output
ts: 2026-08-09
---

# Rust proves you used a resource correctly; it cannot prove you used it at all (belief)

The pitch going in was that Rust falls down across the board on resource
lifecycle, and that the obligation checker's whole surface is territory Rust
cannot reach. That was wrong, and the measurement is unambiguous: of 23 cases,
**five differ, eight are draws, nine are accepted identically by both**.

## What Rust actually gets for free

Every *wrong-phase* mistake — commit before you executed, close right after you
opened, finish a transaction that never began — rustc refuses at compile time
with ordinary typestate. A method implemented only on `Connection<Active>`
produces `E0599: no method named close found for struct Connection<Connected>`.
No macros, no `unsafe`, no crate. This is the pattern a competent Rust developer
reaches for by default, and it is the same class of mistake the obligation
checker exists to catch.

Eight rows were expected to be wins and are draws. **They should be printed as
draws.** A table showing Rust losing 23 out of 23 is dismissed on sight; a table
where Rust wins a class outright and loses exactly one is one people argue
*with* rather than *about*.

## Two of those draws are losses, and the first summary dropped them

The verdict files mark **seven** cases as differing, not five. The two extra —
`2104_12` and `2104_13` — differ *against* Koru, and were silently absent from
the first report of this work. Both compilers refuse the program, so the outcome
is a draw; the architecture behind the refusal is not.

With `--strict-base-types` off — which is those tests' setting — Koru's own
front-end phantom checker compares state tags only, sees two that match, and
passes a wrong-base-type call straight through to code generation. The gate that
actually catches it is the emitted Zig, and the message the author reads is
Zig's, naming Koru's internal generated module paths. Rust has one gate and it is
always on; reaching Koru's default posture there requires a deliberate `unsafe`
transmute, which the probe in `2104_12`'s verdict demonstrates.

**A Koru mistake reported in Zig's voice is a defect, not a fallback.** Fixed
2026-08-10: the check is unconditional now and the flag is deleted. The reason
it had been off was recorded in the source as an accuracy trade — defer to Zig,
which handles type aliases and module qualification properly. Forcing the old
comparison on for a full board falsified that: 5 false positives, all one
defect, none about aliases. It compared MODULE-QUALIFIED forms, and no
type-to-declaring-module map exists anywhere in the checker, so the qualifier is
stamped on with whichever module happens to be writing. Both sides named the
identical type and disagreed on its prefix; three of the five qualified a
primitive, where a prefix is meaningless outright.

**The transferable lesson is about the shape of the excuse.** A guard switched
off "for accuracy" had one narrow bug behind it, and turning the whole guard off
was cheaper to write than finding the bug — so the reason in the comment
outlived the reason in fact, and became the thing everyone read instead of
measuring. The measurement took one board.

Rust's single strongest row is `2104_15`: Koru needed dedicated compiler
behaviour to insert a `close()` on a dropped obligation, where `Drop` hands Rust
the identical guarantee as an ordinary consequence of ownership.

## The strongest form of the thesis is held by an ASYMMETRY, and it is pinned

Acquiring a resource obliges you to use it *meaningfully*; automatic cleanup does
not satisfy that. The Rust side established this is the one property plain
typestate genuinely cannot express at compile time without dependent or session
types — it degrades to a hand-written flag checked at runtime.

Koru holds it, and the mechanism is worth naming because it is reusable design
rather than a checker feature: **the state a resource is born in is not a state
it may be released from.** `tx.begin` yields `started!`; `tx.commit` demands
`!active`; only `tx.exec` bridges them. There is no path from create to free that
does not pass through use, so "opened it and closed it without doing anything" is
not a diagnostic — it is a program that cannot be written. Pinned by
`2104_09_empty_transaction` and `2104_18_open_tx_empty_commit`, both `MUST_ERROR`
on `Phantom state mismatch`.

A resource whose lifecycle *is* symmetric — one state, create and release both
legal against it — silently loses the guarantee, and nothing announces that.
`2104_unused_resources`'s `db.kz` is exactly that shape: `begin()` returns
`Transaction<active!>` with no `started!` phase, so `commit()` is callable the
instant it exists. **The guarantee lives in how the states were drawn, not in the
checker**, which means it is a design obligation on whoever writes the module and
there is nothing today that warns when a lifecycle is drawn without it.

## The one class that breaks

A **forgotten** obligation. A value constructed, matched, and dropped without
ever being used further is completely ordinary Rust — there is nothing in
ownership or borrowck with an opinion about it. Rust's best available analogue
is dynamic: a panic-on-drop guard, the pattern crates like `sqlx` use for
uncommitted transactions. It catches the mistake at drop, in a binary that
already shipped.

## `#[must_use]` is not the backstop, and this is the sharp part

It is the obvious rebuttal and it does not hold. `let _ = expr;` — which is the
natural translation of Koru's own discard — **suppresses the lint entirely, even
under `#![deny(unused_must_use)]`**. Compiles clean, exit 0. Probed directly
rather than argued about.

The strongest fallback remains a `Drop` guard with `mem::forget` on every
legitimate path, which does catch all of them — at runtime, and only if the
author remembered to write the guard, which is the same forgetting the guard was
supposed to prevent.

## The line

> Rust can prove you used a resource *correctly*. It cannot prove you used it
> *at all*.

Related: [[frag-an-obligation-is-a-liveness-interval]],
[[frag-obligation-enforcement-keys-off-return-binding]].
