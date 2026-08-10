# 2104_09_empty_transaction

**Command:**

    cd rust-comparison && rustc --edition 2021 -o /tmp/rustcmp_09 2104_09_empty_transaction.rs

**rustc output (verbatim):**

```
error[E0599]: no method named `commit` found for struct `Transaction<Started>` in the current scope
  --> 2104_09_empty_transaction.rs:93:18
   |
43 | struct Transaction<S> {
   | --------------------- method `commit` not found for this struct
...
93 |     let conn = t.commit().unwrap();
   |                  ^^^^^^ method not found in `Transaction<Started>`
   |
   = note: the method was found for
           - `Transaction<Active>`

error: aborting due to 1 previous error

For more information about this error, try `rustc --explain E0599`.
```

Did not run (compilation failed).

**Rust:** the typestate pattern (zero-sized state markers, `commit`/`rollback` implemented only in `impl Transaction<Active>`) means a `Transaction<Started>` — one that had `begin()` called but never `exec()` — simply has no `commit` method to find; rustc's ordinary method-resolution rules refuse the program with no special machinery.

**Koru:** refuses with `MUST_ERROR "state mismatch"`, `EXPECT: CONTAINS Phantom state mismatch` — `commit` requires `Transaction<!active>`, `begin` only ever produces `Transaction<started!>`.

**DIFFERS: no** — both refuse the identical mistake at compile time, via the same underlying idea (a state-scoped operation isn't available to the wrong state), through different mechanisms (Koru: a first-class phantom-state checker; Rust: ordinary nominal typing over zero-sized marker types).
