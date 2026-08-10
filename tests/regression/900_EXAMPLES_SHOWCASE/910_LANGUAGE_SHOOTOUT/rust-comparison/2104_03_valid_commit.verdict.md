# 2104_03_valid_commit

**Command:**
```
cd rust-comparison && rustc --edition 2021 -o /tmp/rustcmp_2104_03 2104_03_valid_commit.rs
```

**rustc output:** compiled cleanly, no diagnostics. Exit code: 0.

**Program output (`/tmp/rustcmp_2104_03`, exit 0):**
```
Executing: INSERT INTO users VALUES (1, 'alice')
COMMIT
Connection closed
```
This is byte-for-byte identical to Koru's own `expected.txt` for this test.

**What Rust does:** the typestate encoding (`Connection<Connected>` →
`begin()` → `Transaction<Started>` → `exec()` → `Transaction<Active>` →
`commit()` → `Connection<Active>` → `close()`) lets every call in the
happy path type-check, and the program runs exactly the same sequence of
side effects as the Koru program, in the same order.

**What Koru does:** compiles and runs (`input.k` is `MUST_RUN`, not
`MUST_ERROR`) with the identical output.

**DIFFERS: no** — both compile and produce the same output on the happy
path.
