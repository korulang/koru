# 2104_22_open_tx_exec_no_finish

## Command

```
cd rust-comparison && rustc --edition 2021 -o /tmp/rustcmp_2104_22_open_tx_exec_no_finish 2104_22_open_tx_exec_no_finish.rs 2>&1
# then:
/tmp/rustcmp_2104_22_open_tx_exec_no_finish
```

## rustc output

Compiled cleanly, no diagnostics (empty stdout/stderr, exit 0).

## Program output (ran it)

```
Executing: INSERT INTO users VALUES (1, 'alice')

thread 'main' (253318180) panicked at 2104_22_open_tx_exec_no_finish.rs:50:9:
Transaction<active!> (conn 42) dropped without commit()/rollback() -- obligation not discharged
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
```

Exit code: 101 (Rust panic).

## What Rust does

`let _ = tx.exec(...);` — the faithful translation of `input.kz`'s `tx.exec(tx: t, sql: "..."): _` — compiles clean (again, `let _ =` suppresses `must_use`). The executed-but-unfinished transaction is a `TransactionActive`; its `Drop` guard panics at runtime because neither `commit()` nor `rollback()` was ever called.

## What Koru does

Koru refuses to compile `input.kz`: `error[KORU030]: Resource '*Transaction' obligation <active!> was not discharged. Call one of: tx.rollback, tx.commit` (test's own `EXPECT`: `CONTAINS active!`, `CONTAINS was not discharged`, `CONTAINS tx.commit`, `CONTAINS tx.rollback`, `NOT_CONTAINS tx.exec`).

## DIFFERS: yes

Third instance of the same gap: Koru refuses at compile time unconditionally; Rust's ownership model lets the value be executed once and then silently dropped at compile time, catching the mistake only via a hand-added `Drop`-guard panic once the program actually runs.
