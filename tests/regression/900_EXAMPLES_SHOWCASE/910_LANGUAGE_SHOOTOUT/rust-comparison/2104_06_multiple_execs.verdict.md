# 2104_06_multiple_execs

**Command:**
```
cd rust-comparison && rustc --edition 2021 -o /tmp/rustcmp_2104_06 2104_06_multiple_execs.rs
```

**rustc output:** compiled cleanly, no diagnostics. Exit code: 0.

**Program output (`/tmp/rustcmp_2104_06`, exit 0):**
```
Executing: INSERT INTO users VALUES (1, 'alice')
Executing: INSERT INTO users VALUES (2, 'bob')
Executing: INSERT INTO users VALUES (3, 'charlie')
COMMIT
Connection closed
```
This is byte-for-byte identical to Koru's own `expected.txt` for this test.

**What Rust does:** `exec()` is implemented for any `Transaction<S>` where
`S` is `Started` or `Active` (a small marker trait, `UsableForExec`, mirrors
Koru's `<!started|!active>` union), so the same method chains three times in
a row — each call consuming the previous `Transaction<Active>` and producing
a fresh one — before `commit()` and `close()`.

**What Koru does:** compiles and runs (`input.k` is `MUST_RUN`) with the
identical output, for the identical reason: `exec` in `db.kz` accepts
`<!started|!active>` and returns `<active!>`, so it composes.

**DIFFERS: no** — both compile and produce the same output.
