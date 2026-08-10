# 2104_07_serial_transactions

**Command:**
```
cd rust-comparison && rustc --edition 2021 -o /tmp/rustcmp_2104_07 2104_07_serial_transactions.rs
```

**rustc output:** compiled cleanly, no diagnostics. Exit code: 0.

**Program output (`/tmp/rustcmp_2104_07`, exit 0):**
```
Executing: INSERT INTO users VALUES (1, 'alice')
COMMIT
Executing: INSERT INTO users VALUES (2, 'bob')
COMMIT
Connection closed
```
This is byte-for-byte identical to Koru's own `expected.txt` for this test.

**What Rust does:** `begin()` is implemented for any `Connection<S>` where
`S` is `Connected` or `Active` (marker trait `UsableForBegin`, mirroring
Koru's `<!connected|!active>` union), so the `Connection<Active>` returned by
the first `commit()` can be handed straight into a second `begin()` and run
a second transaction on the same connection, before it is finally closed.

**What Koru does:** compiles and runs (`input.k` is `MUST_RUN`) with the
identical output, for the identical reason — `begin` in `db.kz` accepts
`<!connected|!active>`, so a committed connection is reusable.

**DIFFERS: no** — both compile and produce the same output.
