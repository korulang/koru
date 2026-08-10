# 2104_20_open_tx_abandoned

## Command

```
cd rust-comparison && rustc --edition 2021 -o /tmp/rustcmp_2104_20_open_tx_abandoned 2104_20_open_tx_abandoned.rs 2>&1
# then:
/tmp/rustcmp_2104_20_open_tx_abandoned
```

## rustc output

Compiled cleanly, no diagnostics (empty stdout/stderr, exit 0).

## Program output (ran it)

```
thread 'main' (253318040) panicked at 2104_20_open_tx_abandoned.rs:51:9:
Transaction<started!> (conn 42) dropped without exec() -- obligation not discharged
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
```

Exit code: 101 (Rust panic). The `println!` after the discard is never reached.

## What Rust does

`let _ = conn.begin();` — the Koru-faithful translation of `input.kz`'s `tx.begin(conn: c): _` — compiles with **zero diagnostics**: `let _ = expr;` is Rust's own sanctioned discard idiom and it suppresses `#[must_use]`/`unused_must_use` entirely (verified separately: a `#[must_use]` struct discarded via `let _ = make();` under `#![deny(unused_must_use)]` compiles warning-clean, exit 0). The only thing catching the abandoned transaction here is a hand-added `Drop` guard, which panics **at runtime**, the instant the value is dropped.

## What Koru does

Koru refuses to compile `input.kz` at all: `error[KORU030]: Resource '*Transaction' obligation <started!> was not discharged. Call: tx.exec` (test's own `EXPECT`: `CONTAINS not discharged`, `CONTAINS started!`).

## DIFFERS: yes

Koru rejects the program before it ever runs, unconditionally. The Rust version compiles successfully and only fails if and when that exact code path executes — a strictly weaker, runtime-only guarantee. This is the clearest case in the whole slice where Rust cannot match Koru's static guarantee using ownership/typestate alone; a `Drop`-panic guard is the strongest available fallback, and it is a real, honest Rust idiom (the same technique real transaction-guard types use), just not a compile-time one.
