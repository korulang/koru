# 2104_17_open_tx_multiple_execs

## Command

```
cd rust-comparison && rustc --edition 2021 -o /tmp/rustcmp_2104_17_open_tx_multiple_execs 2104_17_open_tx_multiple_execs.rs 2>&1
```

## rustc output

Compiled cleanly, no diagnostics (empty stdout/stderr, exit 0).

## Program output (ran `/tmp/rustcmp_2104_17_open_tx_multiple_execs`)

```
Executing: INSERT INTO users VALUES (1, 'alice')
Executing: INSERT INTO users VALUES (2, 'bob')
Executing: INSERT INTO users VALUES (3, 'charlie')
COMMIT
Connection closed
```

This matches `2104_17_open_tx_multiple_execs/expected.txt` line for line.

## What Rust does

A chain of moves through four distinct typestate structs (`ConnectionConnected` → `TransactionStarted` → `TransactionActive` → `ConnectionActive`) compiles and runs, executing three statements against the transaction before committing and closing — exactly the program `input.k` describes.

## What Koru does

Koru compiles and runs this program too — it carries a `MUST_RUN` marker and a `SUCCESS` marker in the regression tree, with `actual.txt` matching `expected.txt`.

## DIFFERS: no
