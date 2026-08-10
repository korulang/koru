# 2104_05_commit_without_close

**Command:**
```
cd rust-comparison && rustc --edition 2021 -o /tmp/rustcmp_2104_05 2104_05_commit_without_close.rs
```

**rustc output:** compiled cleanly, no diagnostics. Exit code: 0.

**Program output (`/tmp/rustcmp_2104_05`, exit 0):**
```
Executing: INSERT INTO users VALUES (1, 'alice')
COMMIT
Connection closed
```
This is byte-for-byte identical to Koru's own `expected.txt` for this test —
including the "Connection closed" line, even though `close()` is never
called explicitly anywhere in `main()`.

**What Rust does:** after `commit()`, the returned `Connection<Active>` is
bound to `_conn` and dropped at the end of the closure without ever calling
`close()`. Its `Drop` impl notices the obligation is still armed and prints
"Connection closed" itself — a hand-written analogue of Koru's
auto-discharge, triggered at the point of drop rather than by the compiler
rewriting the source.

**What Koru does:** `close()` in `db.kz` is void and single-branch (the sole
event with no `ok`/`err` split), which makes it the one legal auto-discharge
candidate for an abandoned `Connection<active!>`; Koru's compiler inserts
the call itself, so this program compiles and runs (`input.k` is `MUST_RUN`)
and still prints "Connection closed".

**DIFFERS: no** — both produce the identical trace, though by different
mechanisms: Koru inserts the call at compile time (it becomes part of the
program), Rust's `Drop` performs the equivalent side effect at runtime. A
reader diffing only `stdout` would see no difference at all.
