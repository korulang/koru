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
