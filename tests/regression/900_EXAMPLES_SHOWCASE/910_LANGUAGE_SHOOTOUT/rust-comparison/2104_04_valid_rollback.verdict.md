# 2104_04_valid_rollback

**Command:**
```
cd rust-comparison && rustc --edition 2021 -o /tmp/rustcmp_2104_04 2104_04_valid_rollback.rs
```

**rustc output:** compiled cleanly, no diagnostics. Exit code: 0.

**Program output (`/tmp/rustcmp_2104_04`, exit 0):**
```
Executing: INSERT INTO users VALUES (1, 'alice')
ROLLBACK
Connection closed
```
This is byte-for-byte identical to Koru's own `expected.txt` for this test.

**What Rust does:** the same typestate chain as 2104_03, but the transaction
is explicitly rolled back (`Transaction<Active>::rollback`) instead of
committed — the programmer's stated intent, not something Rust or Koru
infers, and both `commit` and `rollback` are equally reachable methods on
`Transaction<Active>`.

**What Koru does:** compiles and runs (`input.k` is `MUST_RUN`) with the
identical output.

**DIFFERS: no** — both compile and produce the same output.
