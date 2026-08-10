# 2104_19_open_tx_close_early

## Command

```
cd rust-comparison && rustc --edition 2021 -o /tmp/rustcmp_2104_19_open_tx_close_early 2104_19_open_tx_close_early.rs 2>&1
```

## rustc output (verbatim)

```
error[E0599]: no method named `close` found for struct `ConnectionConnected` in the current scope
   --> 2104_19_open_tx_close_early.rs:121:10
    |
 21 | struct ConnectionConnected {
    | -------------------------- method `close` not found for this struct
...
121 |     conn.close(); // ERROR: no method `close` on ConnectionConnected
    |          ^^^^^ method not found in `ConnectionConnected`

error: aborting due to 1 previous error

For more information about this error, try `rustc --explain E0599`.
```

Exit code: 1. Program never ran.

## What Rust does

`close()` is implemented only on `ConnectionActive` (the state produced by `commit()`/`rollback()`), not on `ConnectionConnected` (the state produced by `open()`); calling `.close()` straight after `open()` is a real **compile-time** rejection — `E0599: no method named 'close' found for struct 'ConnectionConnected'`.

## What Koru does

Koru refuses to compile `input.kz` with `error[KORU030]: Phantom state mismatch: expected 'app.db:active' but got 'app.db:connected!' for argument 'conn'` (test's own `EXPECT`: `CONTAINS Phantom state mismatch`, `CONTAINS connected!`).

## DIFFERS: no

Both refuse at compile time for the same reason (a freshly-opened connection is not in the state `close` requires); Koru names it via a phantom-state diagnostic, Rust via an ordinary missing-method error.
