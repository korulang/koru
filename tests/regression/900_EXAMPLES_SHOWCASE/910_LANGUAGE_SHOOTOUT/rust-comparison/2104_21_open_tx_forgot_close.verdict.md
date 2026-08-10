# 2104_21_open_tx_forgot_close

## Command

```
cd rust-comparison && rustc --edition 2021 -o /tmp/rustcmp_2104_21_open_tx_forgot_close 2104_21_open_tx_forgot_close.rs 2>&1
# then:
/tmp/rustcmp_2104_21_open_tx_forgot_close
```

## rustc output

Compiled cleanly, no diagnostics (empty stdout/stderr, exit 0).

## Program output (ran it)

```
Executing: INSERT INTO users VALUES (1, 'alice')
COMMIT

thread 'main' (253318109) panicked at 2104_21_open_tx_forgot_close.rs:58:9:
Connection<active!> (42) dropped without close() -- obligation not discharged
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
```

Exit code: 101 (Rust panic). Notice `Executing:` and `COMMIT` both print — the program gets further than 2104_20 before failing, matching how `input.kz` gets one `tx.exec` and a `tx.commit` further before Koru's own checker would refuse it.

## What Rust does

`let _ = tx.commit();` — the faithful translation of `input.kz`'s `tx.commit(tx: r): _` — compiles clean for the same reason as 2104_20 (`let _ =` suppresses `must_use`). The connection returned by `commit()` is a `ConnectionActive`; its `Drop` guard panics at runtime because `close()` was never called on it.

## What Koru does

Koru refuses to compile `input.kz`: `error[KORU030]: Resource '_' carries obligation <active!> was not discharged. Call one of: app.db:close, app.db:tx.begin` (test's own `EXPECT`: `CONTAINS not discharged`, `CONTAINS active!`).

## DIFFERS: yes

Same shape as 2104_20: Koru refuses at compile time unconditionally; Rust compiles and only panics once the discard actually executes at runtime. The `Drop`-guard technique is the strongest fallback available in safe, crate-free Rust, but it is not a static guarantee.
