# 2104_18_open_tx_empty_commit

## Command

```
cd rust-comparison && rustc --edition 2021 -o /tmp/rustcmp_2104_18_open_tx_empty_commit 2104_18_open_tx_empty_commit.rs 2>&1
```

## rustc output (verbatim)

```
error[E0599]: no method named `commit` found for struct `TransactionStarted` in the current scope
   --> 2104_18_open_tx_empty_commit.rs:124:19
    |
 27 | struct TransactionStarted {
    | ------------------------- method `commit` not found for this struct
...
124 |     let conn = tx.commit(); // ERROR: no method `commit` on TransactionStarted
    |                   ^^^^^^ method not found in `TransactionStarted`

error: aborting due to 1 previous error

For more information about this error, try `rustc --explain E0599`.
```

Exit code: 1. Program never ran.

## What Rust does

Encoding `started!` and `active!` as two separate Rust structs, with `commit()` implemented only on the `active!` one, makes calling `commit()` right after `begin()` (with no `exec()` in between) a real **compile-time** rejection — `E0599: no method named 'commit' found for struct 'TransactionStarted'` — using nothing but ordinary inherent-impl scoping, no macros or unsafe.

## What Koru does

Koru refuses to compile `input.kz` with `error[KORU030]: Phantom state mismatch: expected 'app.db:active' but got 'app.db:started!' for argument 'tx'` (test's own `EXPECT`: `CONTAINS Phantom state mismatch`, `CONTAINS started!`).

## DIFFERS: no

Both refuse at compile time, for the same underlying reason (wrong state passed to `commit`), via different diagnostics: Koru names the phantom states explicitly; Rust reports it as an ordinary missing-method error.
